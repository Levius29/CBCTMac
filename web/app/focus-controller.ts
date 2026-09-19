import type { Niivue } from '@niivue/niivue';

type Vec3 = [number, number, number];
export type FocusLocation = { mm: number[]; frac: number[]; visible: boolean };

/** Coordinates remain in NIfTI voxel fractions; interpolation changes only the viewing plane. */
export class FocusController {
  private current: Vec3 = [0.5, 0.5, 0.55];
  private target: Vec3 = [0.5, 0.5, 0.55];
  private frame = 0;
  private enabled = false;
  private visible = false;
  private bookmark: Vec3 | null = null;
  private lastNotify = 0;
  private peer: Niivue | null = null;
  private peerBounds: (inside: boolean) => void = () => {};
  private peerWheel = (event: WheelEvent) => {
    if (this.peer) this.wheelFrom(this.peer, event);
  };
  private readonly originalDraw: Niivue['drawSceneCore'];
  private readonly originalImageDraw: Niivue['drawImage3D'];
  private renderMatrix: ReturnType<Niivue['calculateMvpMatrix']>[0] | null =
    null;
  private readonly wheelCanvas: HTMLCanvasElement;
  private readonly reducedMotion = window.matchMedia(
    '(prefers-reduced-motion: reduce)',
  );

  constructor(
    private readonly render: Niivue,
    private readonly slices: Niivue,
    private readonly onLocation: (location: FocusLocation) => void,
  ) {
    this.originalDraw = render.drawSceneCore.bind(render);
    this.originalImageDraw = render.drawImage3D.bind(render);
    // Reuse the exact matrix used for the current volume pass, including viewport changes.
    render.drawImage3D = (matrix, azimuth, elevation) => {
      this.renderMatrix = matrix;
      this.originalImageDraw(matrix, azimuth, elevation);
    };
    // Draw into the same WebGL frame: stays aligned during orbit, zoom, resize and PNG export.
    render.drawSceneCore = () => {
      const result = this.originalDraw.call(render);
      if (this.enabled && render.volumes.length && render.canvas?.clientWidth)
        this.drawMarkers();
      return result;
    };
    slices.onLocationChange = (value: unknown) => {
      const location = value as { frac?: number[] };
      if (this.enabled && location.frac)
        this.moveTo(Array.from(location.frac) as Vec3);
    };
    this.wheelCanvas = slices.canvas!;
    this.wheelCanvas.addEventListener('wheel', this.onWheel, {
      capture: true,
      passive: false,
    });
  }

  pause() {
    this.enabled = false;
    this.visible = false;
    cancelAnimationFrame(this.frame);
  }

  reset(frac: Vec3, reveal = false) {
    cancelAnimationFrame(this.frame);
    this.current = [...frac];
    this.target = [...frac];
    this.visible = reveal;
    this.enabled = true;
    this.apply();
    this.notify();
  }

  setBookmark(frac: number[] | null) {
    this.bookmark = frac ? ([...frac] as Vec3) : null;
    if (this.enabled) this.render.drawScene();
  }

  getWorldPoint(): number[] | null {
    return this.slices.volumes.length
      ? Array.from(this.slices.frac2mm(this.current, 0, true)).slice(0, 3)
      : null;
  }

  redrawPeer() {
    this.peer?.drawScene();
  }

  setPeer(peer: Niivue | null, onBounds: (inside: boolean) => void = () => {}) {
    if (this.peer) {
      this.peer.canvas?.removeEventListener('wheel', this.peerWheel, true);
      this.peer.onLocationChange = () => {};
    }
    this.peer = peer;
    this.peerBounds = onBounds;
    if (!peer) return;
    peer.opts.isSliceMM = true;
    peer.onLocationChange = (value) => {
      const location = value as { mm?: number[] };
      if (this.enabled && location.mm)
        this.moveToWorld(Array.from(location.mm).slice(0, 3));
    };
    peer.canvas?.addEventListener('wheel', this.peerWheel, {
      capture: true,
      passive: false,
    });
    this.syncPeer();
  }

  moveToWorld(mm: number[]) {
    if (!this.slices.volumes.length || !mm.every(Number.isFinite)) return;
    // Keep the same physical point even outside the other volume's field of view.
    this.moveTo(Array.from(this.slices.mm2frac(mm, 0, true)) as Vec3, false);
  }

  moveTo(frac: Vec3, clamp = true) {
    if (!this.enabled || frac.length !== 3 || !frac.every(Number.isFinite))
      return;
    cancelAnimationFrame(this.frame);
    const from = [...this.current] as Vec3;
    this.target = frac.map((v) =>
      clamp ? Math.max(0, Math.min(1, v)) : v,
    ) as Vec3;
    this.visible = true;
    if (this.reducedMotion.matches) {
      this.current = [...this.target];
      this.apply();
      this.notify();
      return;
    }
    const started = performance.now();
    const duration = 110;
    // Reset the native immediate click before the next browser paint, then glide to its exact target.
    this.apply();
    const tick = (now: number) => {
      if (!this.enabled) return;
      const progress = Math.min(1, (now - started) / duration);
      const eased = 1 - Math.pow(1 - progress, 3);
      this.current =
        progress === 1
          ? [...this.target]
          : (from.map((v, i) => v + (this.target[i] - v) * eased) as Vec3);
      this.apply();
      if (now - this.lastNotify > 45 || progress === 1) {
        this.notify();
        this.lastNotify = now;
      }
      if (progress < 1) this.frame = requestAnimationFrame(tick);
    };
    this.frame = requestAnimationFrame(tick);
  }

  private onWheel = (event: WheelEvent) => this.wheelFrom(this.slices, event);

  private wheelFrom(nv: Niivue, event: WheelEvent) {
    if (
      !this.enabled ||
      event.ctrlKey ||
      event.metaKey ||
      event.altKey ||
      event.shiftKey ||
      !event.deltaY
    )
      return;
    const canvas = nv.canvas!;
    const rect = canvas.getBoundingClientRect();
    const x = ((event.clientX - rect.left) * canvas.width) / rect.width;
    const y = ((event.clientY - rect.top) * canvas.height) / rect.height;
    const index = nv.tileIndex(x, y);
    const tile = nv.screenSlices[index];
    if (!tile || tile.axCorSag > 2) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    const axis = [2, 1, 0][tile.axCorSag];
    const dim = nv.volumes[0].dimsRAS![axis + 1];
    const pixels =
      event.deltaY *
      (event.deltaMode === 1 ? 18 : event.deltaMode === 2 ? rect.height : 1);
    const voxels = Math.max(-4, Math.min(4, pixels / 50));
    const direction = nv.opts.invertScrollDirection ? -1 : 1;
    if (nv.opts.isSliceMM) {
      const world = Array.from(this.slices.frac2mm(this.target, 0, true)).slice(
        0,
        3,
      );
      world[axis] += direction * voxels; // 1 mm per 50px, without oblique-axis drift.
      const frac = nv.mm2frac(world, 0, true);
      if (Array.from(frac).some((v) => v < 0 || v > 1)) return;
      this.moveToWorld(world);
      return;
    }
    const next = [...this.target] as Vec3;
    next[axis] = Math.max(
      0.5 / dim,
      Math.min(1 - 0.5 / dim, next[axis] + (direction * voxels) / dim),
    );
    this.moveTo(next);
  }

  private syncPeer() {
    if (!this.peer?.volumes.length || !this.slices.volumes.length) return;
    const mm = this.slices.frac2mm(this.current, 0, true);
    const frac = Array.from(this.peer.mm2frac(mm, 0, true));
    this.peer.scene.crosshairPos = frac as Vec3;
    this.peerBounds(frac.every((v) => v >= 0 && v <= 1));
    this.peer.drawScene();
  }

  private apply() {
    this.slices.scene.crosshairPos = [...this.current];
    this.render.scene.crosshairPos = [...this.current];
    this.render.opts.show3Dcrosshair = false;
    this.slices.drawScene();
    this.render.drawScene();
    this.syncPeer();
  }

  private notify() {
    this.onLocation({
      mm: Array.from(this.slices.frac2mm(this.current, 0, true)).slice(0, 3),
      frac: [...this.current],
      visible: this.visible,
    });
  }

  private project(frac: Vec3) {
    const nv = this.render;
    const rect = nv.screenSlices?.find((tile) => tile.axCorSag === 4)
      ?.leftTopWidthHeight || [0, 0, nv.canvas!.width, nv.canvas!.height];
    const matrix =
      this.renderMatrix ||
      nv.calculateMvpMatrix(
        null,
        rect,
        nv.scene.renderAzimuth,
        nv.scene.renderElevation,
      )[0];
    // Volume rendering uses patient/world coordinates, also for oblique source images.
    const mm = nv.frac2mm(frac, 0, true);
    return nv.calculateScreenPoint([mm[0], mm[1], mm[2]], matrix, rect);
  }

  private drawMarkers() {
    const nv = this.render;
    // A cached 3D matrix must never project a marker onto a 2D-only layout.
    if (!nv.screenSlices?.some((tile) => tile.axCorSag === 4)) return;
    const gl = nv.gl;
    const depthEnabled = gl.isEnabled(gl.DEPTH_TEST);
    const blendEnabled = gl.isEnabled(gl.BLEND);
    const program = gl.getParameter(gl.CURRENT_PROGRAM);
    const vao = gl.getParameter(gl.VERTEX_ARRAY_BINDING);
    const viewport = gl.getParameter(gl.VIEWPORT);
    const depthMask = gl.getParameter(gl.DEPTH_WRITEMASK);
    const blend = [
      gl.BLEND_SRC_RGB,
      gl.BLEND_DST_RGB,
      gl.BLEND_SRC_ALPHA,
      gl.BLEND_DST_ALPHA,
    ].map((p) => gl.getParameter(p));
    gl.depthMask(false);
    gl.disable(gl.DEPTH_TEST);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.viewport(0, 0, nv.canvas!.width, nv.canvas!.height);
    const draw = (
      frac: Vec3,
      label: string,
      color: number[],
      leader: boolean,
    ) => {
      const projected = this.project(frac);
      const x = projected[0];
      const y = projected[1];
      const w = nv.canvas!.width;
      const h = nv.canvas!.height;
      if (!Number.isFinite(x + y) || x < 0 || y < 0 || x > w || y > h) return;
      nv.drawCircle([x - 19, y - 19, 38, 38], [...color.slice(0, 3), 0.1]);
      nv.drawCircle([x - 11, y - 11, 22, 22], [0.025, 0.035, 0.04, 0.85]);
      nv.drawCircle([x - 10, y - 10, 20, 20], color, 0.2);
      nv.drawCircle([x - 2.5, y - 2.5, 5, 5], color);
      if (leader) {
        const tx = Math.min(w - 90, Math.max(22, x + 46));
        const ty = Math.max(72, y - 40);
        nv.drawLine([x + 9, y - 7, tx - 6, ty + 10], 1, [
          ...color.slice(0, 3),
          0.7,
        ]);
        nv.drawRect([tx - 4, ty - 2, 68, 24], [0.035, 0.055, 0.06, 0.88]);
        nv.drawText([tx + 2, ty + 1], label, 0.95, color);
      }
    };
    if (this.bookmark)
      draw(this.bookmark, '01', [0.65, 0.95, 0.78, 0.95], false);
    if (this.visible) draw(this.current, 'FOCUS', [1, 0.77, 0.4, 1], true);
    if (depthEnabled) gl.enable(gl.DEPTH_TEST);
    if (!blendEnabled) gl.disable(gl.BLEND);
    gl.depthMask(depthMask);
    gl.blendFuncSeparate(blend[0], blend[1], blend[2], blend[3]);
    gl.viewport(viewport[0], viewport[1], viewport[2], viewport[3]);
    gl.bindVertexArray(vao);
    gl.useProgram(program);
  }

  dispose() {
    this.pause();
    this.setPeer(null);
    this.wheelCanvas.removeEventListener('wheel', this.onWheel, true);
    this.render.drawSceneCore = this.originalDraw;
    this.render.drawImage3D = this.originalImageDraw;
    this.slices.onLocationChange = () => {};
  }
}
