const localVideo = document.getElementById('localVideo');
const captureCanvas = document.getElementById('captureCanvas');
const remoteImg = document.getElementById('remoteImg');

const startBtn = document.getElementById('startBtn');
const loadConfigBtn = document.getElementById('loadConfigBtn');
const createSessionBtn = document.getElementById('createSessionBtn');
const startSessionBtn = document.getElementById('startSessionBtn');
const stopSessionBtn = document.getElementById('stopSessionBtn');
const connectBtn = document.getElementById('connectBtn');
const startStreamBtn = document.getElementById('startStreamBtn');
const stopStreamBtn = document.getElementById('stopStreamBtn');

const apiBaseUrlInput = document.getElementById('apiBaseUrl');
const wsStatus = document.getElementById('wsStatus');
const sessionStatusEl = document.getElementById('sessionStatus');
const sessionIdEl = document.getElementById('sessionId');
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
let currentSession = null;

function getApiBaseUrl() {
  return (apiBaseUrlInput.value.trim() || window.location.origin).replace(/\/+$/, '');
}

function getAuthHeaders() {
  const token = tokenInput.value.trim();
  return token ? { Authorization: `****** } : {};
}

function setSession(record) {
  currentSession = record || null;
  sessionStatusEl.textContent = currentSession?.status || 'not-created';
  sessionIdEl.textContent = currentSession?.session_id || '-';
  startSessionBtn.disabled = !currentSession || currentSession.status === 'active';
  stopSessionBtn.disabled = !currentSession || currentSession.status === 'stopped';
  if (currentSession?.ws_url) {
    wsUrlInput.value = currentSession.ws_url;
  }
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, options);
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.detail || `Request failed (${response.status})`);
  }
  return payload;
}

fpsInput.addEventListener('input', () => {
  fpsVal.textContent = fpsInput.value;
});

apiBaseUrlInput.value = window.location.origin === 'null' ? 'http://localhost' : window.location.origin;

startBtn.onclick = async () => {
  const [w, h] = resolutionSelect.value.split('x').map((v) => parseInt(v, 10));
  try {
    localStream = await navigator.mediaDevices.getUserMedia({
      video: { width: w, height: h, facingMode: 'user' },
      audio: false,
    });
    localVideo.srcObject = localStream;
    const trackSettings = localStream.getVideoTracks()[0].getSettings();
    captureCanvas.width = trackSettings.width || w;
    captureCanvas.height = trackSettings.height || h;
  } catch (err) {
    alert(`Camera error: ${err.message}`);
    console.error(err);
  }
};

loadConfigBtn.onclick = async () => {
  try {
    const config = await fetchJson(`${getApiBaseUrl()}/v1/client-config`);
    if (config.ws_url) {
      wsUrlInput.value = config.ws_url;
    }
  } catch (err) {
    alert(err.message);
  }
};

createSessionBtn.onclick = async () => {
  try {
    const payload = {
      client_name: 'pwa-demo',
      transport: 'ws',
      resolution: resolutionSelect.value,
      fps: parseInt(fpsInput.value, 10),
      metadata: { client: 'frontend-pwa' },
    };
    const session = await fetchJson(`${getApiBaseUrl()}/v1/sessions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...getAuthHeaders(),
      },
      body: JSON.stringify(payload),
    });
    setSession(session);
  } catch (err) {
    alert(err.message);
  }
};

startSessionBtn.onclick = async () => {
  if (!currentSession) {
    alert('Create a session first');
    return;
  }
  try {
    const session = await fetchJson(`${getApiBaseUrl()}/v1/sessions/${currentSession.session_id}/start`, {
      method: 'POST',
      headers: getAuthHeaders(),
    });
    setSession(session);
  } catch (err) {
    alert(err.message);
  }
};

stopSessionBtn.onclick = async () => {
  if (!currentSession) {
    return;
  }
  try {
    const session = await fetchJson(`${getApiBaseUrl()}/v1/sessions/${currentSession.session_id}/stop`, {
      method: 'POST',
      headers: getAuthHeaders(),
    });
    setSession(session);
  } catch (err) {
    alert(err.message);
  }
};

connectBtn.onclick = () => {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.close();
    return;
  }

  const url = wsUrlInput.value.trim();
  if (!url) {
    alert('Set WS URL');
    return;
  }

  const wsTarget = new URL(url, window.location.origin);
  const token = tokenInput.value.trim();
  if (token) {
    wsTarget.searchParams.set('token', token);
  }
  if (currentSession?.session_id) {
    wsTarget.searchParams.set('session_id', currentSession.session_id);
  }

  ws = new WebSocket(wsTarget.toString());
  ws.binaryType = 'arraybuffer';
  wsStatus.textContent = 'connecting';
  ws.onopen = () => {
    wsStatus.textContent = 'open';
  };
  ws.onclose = () => {
    wsStatus.textContent = 'closed';
  };
  ws.onerror = (e) => {
    wsStatus.textContent = 'error';
    console.error(e);
  };
  ws.onmessage = async (evt) => {
    if (evt.data instanceof ArrayBuffer) {
      const blob = new Blob([evt.data], { type: 'image/jpeg' });
      const urlObject = URL.createObjectURL(blob);
      remoteImg.src = urlObject;
      setTimeout(() => URL.revokeObjectURL(urlObject), 1000);
      recvCount += 1;
      recvCountEl.textContent = String(recvCount);
      if (lastSentTs) {
        latencyEl.textContent = String(Date.now() - lastSentTs);
      }
      awaitingResponse = false;
      return;
    }

    try {
      const txt = await evt.data.text();
      console.log('ws text:', txt);
    } catch (e) {
      console.log('ws msg', evt.data);
    }
  };
};

function captureFrameBlob(quality = 0.7) {
  const ctx = captureCanvas.getContext('2d');
  ctx.drawImage(localVideo, 0, 0, captureCanvas.width, captureCanvas.height);
  return new Promise((resolve) => {
    captureCanvas.toBlob((blob) => resolve(blob), 'image/jpeg', quality);
  });
}

startStreamBtn.onclick = () => {
  if (!ws || ws.readyState !== WebSocket.OPEN) {
    alert('WS not connected');
    return;
  }
  if (!localStream) {
    alert('Start camera first');
    return;
  }
  const fps = Math.max(1, parseInt(fpsInput.value || '8', 10));
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
  if (streamInterval) {
    clearInterval(streamInterval);
    streamInterval = null;
  }
  startStreamBtn.disabled = false;
  stopStreamBtn.disabled = true;
};

if ('serviceWorker' in navigator) {
  navigator.serviceWorker
    .register('/service-worker.js')
    .then(() => console.log('SW registered'))
    .catch(() => {});
}
