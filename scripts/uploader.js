// Detached R2 source-master uploader for mbr2 (survives plane crashes).
// Run every 15 min via scheduled task; a pidfile lock keeps ONE process alive.
// If the process died, the next invocation aborts the stale multipart and
// restarts the current source from 0.
const fs = require('fs');
const path = require('path');
const { S3Client, ListObjectsV2Command, HeadObjectCommand, ListMultipartUploadsCommand, ListPartsCommand, AbortMultipartUploadCommand } = require('@aws-sdk/client-s3');
const { Upload } = require('@aws-sdk/lib-storage');

const DIR = process.env.UPLOAD_DIR || 'C:\\Users\\sebbe\\slyce-uploader';
const LOCK = path.join(DIR, 'uploader.lock');
const LOG = path.join(DIR, 'uploader.log');
const STATE = path.join(DIR, 'progress.json');

let CFG;
const CFG_PATH = path.join(DIR, 'config.json');
if (fs.existsSync(CFG_PATH)) {
  CFG = JSON.parse(fs.readFileSync(CFG_PATH, 'utf8'));
} else {
CFG = {
  endpoint: process.env.R2_ENDPOINT,
  access: process.env.R2_ACCESS,
  secret: process.env.R2_SECRET,
  bucket: process.env.R2_BUCKET,
  prefix: 'mbr2',
  // sourceKey -> local relative dir (underscore form)
  targets: JSON.parse(process.env.TARGETS || '[]'),
  sanity: { host: process.env.SANITY_HOST, dataset: 'production', token: process.env.SANITY_TOKEN },
  storageHost: process.env.STORAGE_HOST,
};
}
CFG.targets = CFG.targets || JSON.parse(process.env.TARGETS || '[]');
CFG.videosDir = CFG.videosDir || 'C:\\Users\\sebbe\\Videos';

function log(m) { const line = new Date().toISOString() + ' ' + m; fs.appendFileSync(LOG, line + '\n'); console.log(line); }
function s3() { return new S3Client({ region: 'auto', endpoint: CFG.endpoint, credentials: { accessKeyId: CFG.access, secretAccessKey: CFG.secret } }); }
function keyFor(dir) { return CFG.prefix + '/' + dir + '/PROGRAM.mp4'; }
function localFor(dir) { return path.join(CFG.videosDir, dir, 'PROGRAM.mp4'); }

function lockAlive() {
  try {
    if (!fs.existsSync(LOCK)) return null;
    const pid = parseInt(fs.readFileSync(LOCK, 'utf8'), 10);
    if (!pid) return 'stale';
    try { process.kill(pid, 0); return 'alive'; } catch { return 'stale'; }
  } catch { return 'stale'; }
}

async function uploadOne(s3c, dir) {
  const key = keyFor(dir);
  const local = localFor(dir);
  if (!fs.existsSync(local)) { log('SKIP (no local file): ' + dir); return 'done'; }
  const localSize = fs.statSync(local).size;

  // already complete in R2?
  try {
    const h = await s3c.send(new HeadObjectCommand({ Bucket: CFG.bucket, Key: key }));
    if (h.ContentLength >= localSize * 0.99) { log('ALREADY COMPLETE: ' + dir + ' (' + (h.ContentLength/1e9).toFixed(1) + 'GB)'); return 'done'; }
  } catch (e) { if (e.name !== 'NotFound' && e.$metadata?.httpStatusCode !== 404) log('HEAD err: ' + e.message); }

  // in-flight multipart?
  const ups = await s3c.send(new ListMultipartUploadsCommand({ Bucket: CFG.bucket, Prefix: key }));
  const up = (ups.Uploads || []).filter(u => u.Key === key).sort((a,b) => b.Initiated - a.Initiated)[0];
  if (up) {
    try {
      const parts = await s3c.send(new ListPartsCommand({ Bucket: CFG.bucket, Key: key, UploadId: up.UploadId }));
      const list = parts.Parts || [];
      const last = list.length ? list[list.length-1].LastModified : null;
      const total = list.reduce((s,p) => s + p.Size, 0);
      if (last && (Date.now() - last.getTime()) < 5*60*1000) {
        log('UPLOAD IN PROGRESS (pid lock stale but parts fresh): ' + dir + ' ' + (total/1e9).toFixed(1) + 'GB — exiting');
        return 'in-progress';
      }
      log('STALE multipart (' + (total/1e9).toFixed(1) + 'GB, last part ' + (last ? last.toISOString() : '?') + ') — aborting + restarting ' + dir);
      await s3c.send(new AbortMultipartUploadCommand({ Bucket: CFG.bucket, Key: key, UploadId: up.UploadId }));
    } catch (e) { log('multipart inspect err: ' + e.message); }
  }

  log('STARTING: ' + dir + ' (' + (localSize/1e9).toFixed(1) + 'GB)');
  const upload = new Upload({
    client: s3c,
    params: { Bucket: CFG.bucket, Key: key, Body: fs.createReadStream(local) },
    queueSize: 8, partSize: 1024*1024*16, leavePartsOnError: false,
  });
  upload.on('httpUploadProgress', (p) => {
    if (p.loaded && p.total && p.loaded % (1024*1024*1024) < 16*1024*1024) {
      fs.writeFileSync(STATE, JSON.stringify({ source: dir, loaded: p.loaded, total: p.total, at: new Date().toISOString() }));
    }
  });
  await upload.done();
  log('UPLOADED: ' + dir);
  await patchSanity(dir, key, localSize);
  log('PATCHED sanity for ' + dir);
  return 'done';
}

async function patchSanity(dir, key, size) {
  if (!CFG.sanity.token) { log('no sanity token — skip patch'); return; }
  const sourceId = 'mbr2__' + dir.replace(/[\\\/]/g, '_') + '__PROGRAM';
  const publicUrl = CFG.storageHost + '/' + key;
  const body = { mutations: [{ patch: { id: sourceId, set: { s3Object: {
    _type: 'slyceFileReference', Key: key, ContentLength: size, bucket: CFG.bucket, publicUrl,
  } } } }] };
  try {
    const r = await fetch('https://' + CFG.sanity.host + '/v2021-06-07/data/mutate/' + CFG.sanity.dataset,
      { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + CFG.sanity.token }, body: JSON.stringify(body) });
    log('sanity mutate ' + r.status + ' ' + (await r.text()).slice(0, 120));
  } catch (e) { log('sanity patch err: ' + e.message); }
}

async function main() {
  const lock = lockAlive();
  if (lock === 'alive') { console.log('another instance running — exit'); return; }
  fs.writeFileSync(LOCK, String(process.pid));

  const s3c = s3();
  // resume from the first incomplete target
  for (const dir of CFG.targets) {
    const res = await uploadOne(s3c, dir);
    if (res === 'in-progress') break; // someone else uploading — stop
    if (res === 'done') continue;
    break;
  }
  log('run complete');
  try { fs.unlinkSync(LOCK); } catch {}
  process.exit(0);
}

main().catch(e => { log('FATAL: ' + (e.stack || e.message)); try { fs.unlinkSync(LOCK); } catch {} process.exit(1); });
