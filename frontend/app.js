const localVideo = document.getElementById('localVideo');
const captureCanvas = document.getElementById('captureCanvas');
const remoteImg = document.getElementById('remoteImg');

const startBtn = document.getElementById('startBtn');
const connectBtn = document.getElementById('connectBtn');
const startStreamBtn = document.getElementById('startStreamBtn');
const stopStreamBtn = document.getElementById('stopStreamBtn');

const wsStatus = document.getElementById('wsStatus');
const sentCountEl = document.getElementById('sentCount');
const recvCountEl = document.getElementById('recvCount');
const latencyEl = document.getElementById('latency');
const fpsInput = document.getElementById('fps');
const fpsVal = document.getElementById('fpsVal');
const resolutionSelect = document.getElementById('resolution');

const wsUrlInput = document.getElementById('wsUrl');
const tokenInput = document.getElementById('token');

let localStream = null;
let ws = null;
let streamInterval = null;
let awaitingResponse = false;
let sentCount = 0;
let recvCount = 0;
let lastSentTs = 0;

fpsInput.addEventListener('input', () => fpsVal.textContent = fpsInput.value);

startBtn.onclick = async () => {
  const [w,h] = resolutionSelect.value.split('x').map(v=>parseInt(v));
  try {
    localStream = await navigator.mediaDevices.getUserMedia({ video: { width: w, height: h, facingMode: 'user' }, audio: false });
    localVideo.srcObject = localStream;
    const trackSettings = localStream.getVideoTracks()[0].getSettings();
    captureCanvas.width = trackSettings.width || w;
    captureCanvas.height = trackSettings.height || h;
  } catch (err) {
    alert('Camera error: ' + err.message);
    console.error(err);
  }
};

connectBtn.onclick = () => {
  if (ws && ws.readyState === WebSocket.OPEN) { ws.close(); return; }
  const url = wsUrlInput.value.trim();
  if (!url) { alert('Set WS URL'); return; }
  const token = encodeURIComponent(tokenInput.value.trim() || '');
  const fullUrl = url.includes('?') ? (url + '&token=' + token) : (url + '?token=' + token);
  ws = new WebSocket(fullUrl);
  ws.binaryType = 'arraybuffer';
  wsStatus.textContent = 'connecting';
  ws.onopen = () => { wsStatus.textContent = 'open'; console.log('ws open'); };
  ws.onclose = () => { wsStatus.textContent = 'closed'; console.log('ws close'); };
  ws.onerror = (e) => { wsStatus.textContent = 'error'; console.error(e); };
  ws.onmessage = async (evt) => {
    if (evt.data instanceof ArrayBuffer) {
      const blob = new Blob([evt.data], {type:'image/jpeg'});
      const url = URL.createObjectURL(blob);
      remoteImg.src = url;
      setTimeout(()=>URL.revokeObjectURL(url), 1000);
      recvCount += 1;
      recvCountEl.textContent = String(recvCount);
      if (lastSentTs) {
        const rtt = Date.now() - lastSentTs;
        latencyEl.textContent = String(rtt);
      }
      awaitingResponse = false;
    } else {
      try {
        const txt = await evt.data.text();
        console.log('ws text:', txt);
      } catch(e) { console.log('ws msg', evt.data); }
    }
  };
};

function captureFrameBlob(quality=0.7) {
  const ctx = captureCanvas.getContext('2d');
  ctx.drawImage(localVideo, 0, 0, captureCanvas.width, captureCanvas.height);
  return new Promise((resolve) => {
    captureCanvas.toBlob((blob) => resolve(blob), 'image/jpeg', quality);
  });
}

startStreamBtn.onclick = () => {
  if (!ws || ws.readyState !== WebSocket.OPEN) { alert('WS not connected'); return; }
  if (!localStream) { alert('Start camera first'); return; }
  const fps = Math.max(1, parseInt(fpsInput.value || 8));
  const intervalMs = Math.round(1000 / fps);
  streamInterval = setInterval(async () => {
    if (awaitingResponse) return;
    const blob = await captureFrameBlob(0.6);
    if (!blob) return;
    try {
      lastSentTs = Date.now();
      ws.send(await blob.arrayBuffer());
      awaitingResponse = true;
      sentCount += 1;
      sentCountEl.textContent = String(sentCount);
    } catch (e) {
      console.error('send error', e);
    }
  }, intervalMs);
  startStreamBtn.disabled = true;
  stopStreamBtn.disabled = false;
};

stopStreamBtn.onclick = () => {
  if (streamInterval) { clearInterval(streamInterval); streamInterval = null; }
  startStreamBtn.disabled = false;
  stopStreamBtn.disabled = true;
};

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/service-worker.js').then(() => console.log('SW registered')).catch(()=>{});
}