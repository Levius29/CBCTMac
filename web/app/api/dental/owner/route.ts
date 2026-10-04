import { archiveOwner } from '@/lib/dental-import';
import { failure } from '@/lib/library';

/**
 * Di chi è già questo archivio, se è già in libreria.
 *
 * Serve a chi ritenta: la seconda importazione dello stesso esame, con un paziente nuovo, si
 * fermava su «This archive was already imported for another patient». Sapendo il paziente di
 * prima, la si conferma per lui, e il motore risponde che l'esame c'è già — e lo apre.
 */
export function GET(request: Request) {
  try {
    const job = new URL(request.url).searchParams.get('job') || '';
    return Response.json(
      { patientId: archiveOwner(job) },
      { headers: { 'Cache-Control': 'no-store' } },
    );
  } catch (e) {
    return failure(e);
  }
}
