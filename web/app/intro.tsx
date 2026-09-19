'use client';
import { useCallback, useEffect, useRef, useState } from 'react';
import { Volume2, VolumeX } from 'lucide-react';

const VIDEO = '/welcome/enter.mp4';
const POSTER = '/welcome/hero.jpg';
/** The clip is five seconds; nothing may hold the workspace longer than this. */
const MAX_MS = 6500;
const REDUCED_MS = 900;
const SOUND_KEY = 'openmri-intro-sound';

/** Browsers that ignore volume changes, such as iOS Safari, simply stop. */
function fadeOutAndPause(v: HTMLVideoElement, ms: number) {
  const start = performance.now();
  const step = (now: number) => {
    const k = Math.min(1, (now - start) / ms);
    v.volume = 1 - k;
    if (k < 1) requestAnimationFrame(step);
    else v.pause();
  };
  requestAnimationFrame(step);
}

/**
 * Full-screen transition shown while the viewer mounts behind it. It ends when
 * the clip ends, when the user skips, or at the hard cap, whichever is first.
 */
export default function Intro({
  title,
  subtitle,
  onDone,
}: {
  title: string;
  subtitle: string;
  onDone: () => void;
}) {
  const video = useRef<HTMLVideoElement>(null);
  const finished = useRef(false);
  const [leaving, setLeaving] = useState(false);
  const [sound, setSound] = useState(() => {
    try {
      return localStorage.getItem(SOUND_KEY) !== 'off';
    } catch {
      return true;
    }
  });
  const finish = useCallback(() => {
    if (finished.current) return;
    finished.current = true;
    setLeaving(true);
    const v = video.current;
    // A skip must not cut the music hard: ramp the volume down over the
    // overlay fade, then pause.
    if (v && !v.muted && !v.paused && !v.ended) fadeOutAndPause(v, 300);
    window.setTimeout(onDone, 350);
  }, [onDone]);

  useEffect(() => {
    const reduced = window.matchMedia(
      '(prefers-reduced-motion: reduce)',
    ).matches;
    const cap = window.setTimeout(finish, reduced ? REDUCED_MS : MAX_MS);
    const v = video.current;
    if (v && !reduced) {
      // After a click on the page the browser allows sound. Without one, for
      // example when a script opened the app, it refuses: play muted and say
      // so, and one click on the sound button brings the music in.
      v.play().catch(() => {
        v.muted = true;
        setSound(false);
        v.play().catch(() => window.setTimeout(finish, REDUCED_MS));
      });
    }
    return () => {
      window.clearTimeout(cap);
      v?.pause();
    };
  }, [finish]);

  useEffect(() => {
    if (video.current) video.current.muted = !sound;
  }, [sound]);

  function toggleSound() {
    const next = !sound;
    setSound(next);
    try {
      localStorage.setItem(SOUND_KEY, next ? 'on' : 'off');
    } catch {
      /* Local storage is optional. */
    }
  }

  return (
    <div className={`intro ${leaving ? 'leaving' : ''}`}>
      {/* oxlint-disable-next-line jsx-a11y/media-has-caption -- decorative clip without speech, hidden from assistive tech */}
      <video
        ref={video}
        className="intro-video"
        src={VIDEO}
        poster={POSTER}
        muted={!sound}
        playsInline
        preload="auto"
        onEnded={finish}
        onError={() => window.setTimeout(finish, REDUCED_MS)}
        aria-hidden="true"
      />
      <div className="intro-shade" aria-hidden="true" />
      <div className="intro-text">
        <span className="eyebrow">OPENING</span>
        <h1>{title}</h1>
        <p>{subtitle}</p>
        <div className="intro-loading" aria-live="polite">
          <span className="intro-bar" aria-hidden="true" />
          <span>
            Loading<i aria-hidden="true">...</i>
          </span>
        </div>
      </div>
      <div className="intro-controls">
        <button onClick={toggleSound} aria-pressed={sound}>
          {sound ? <Volume2 size={14} /> : <VolumeX size={14} />}
          {sound ? 'Sound on' : 'Sound off'}
        </button>
        <button onClick={finish}>Skip</button>
      </div>
    </div>
  );
}
