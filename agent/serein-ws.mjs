/**
 * serein-ws — WS 发送队列 + 心跳管理
 *
 * 从 serein.mjs 提取，降低主文件体积。
 * 使用工厂函数创建实例，通过 getter 函数获取外部引用（ws, sessionId）。
 */

// ── WS 发送队列（替代即时丢弃的背压机制）──
function createWsSendQueue(getWs) {
  const wsSendQueue = [];
  let wsSending = false;
  const WS_SEND_QUEUE_MAX = 200;
  const WS_SEND_BACKPRESSURE = 256 * 1024;

  function wsProcessSendQueue() {
    if (wsSendQueue.length === 0) {
      wsSending = false;
      return;
    }
    const ws = getWs();
    if (!ws || ws.readyState !== 1) {  // WebSocket.OPEN === 1
      wsSending = false;
      return;
    }
    try {
      if (ws.bufferedAmount > WS_SEND_BACKPRESSURE) {
        setTimeout(wsProcessSendQueue, 10);
        return;
      }
    } catch { /* bufferedAmount 不可用 */ }
    const msg = wsSendQueue.shift();
    try {
      ws.send(msg);
    } catch {
      wsSendQueue.unshift(msg);
      wsSending = false;
      return;
    }
    setImmediate(wsProcessSendQueue);
  }

  function wsEnqueue(msg) {
    if (wsSendQueue.length >= WS_SEND_QUEUE_MAX) {
      wsSendQueue.shift();
    }
    wsSendQueue.push(msg);
    if (!wsSending) {
      wsSending = true;
      setImmediate(wsProcessSendQueue);
    }
  }

  // A reconnect keeps messages that were queued before the socket closed.
  // Resume only after the new socket has completed join, otherwise cmd_step
  // could become the first frame and fail the backend's join handshake.
  function resumeWsSendQueue() {
    if (wsSendQueue.length > 0 && !wsSending) {
      wsSending = true;
      setImmediate(wsProcessSendQueue);
    }
  }

  function clearWsSendQueue() {
    wsSendQueue.length = 0;
    wsSending = false;
  }

  /**
   * Wait until queued frames have been handed to the WebSocket.
   *
   * Desktop history replay can contain hundreds of small structured events.
   * Letting all of them enter the bounded queue in one synchronous loop would
   * evict the control frame at the head (for example desktop_thread_taken).
   * Callers use this as backpressure between bounded replay batches.
   */
  async function waitForQueueBelow(limit = 0, timeoutMs = 2000) {
    const target = Math.max(0, Number(limit) || 0);
    const deadline = Date.now() + Math.max(0, Number(timeoutMs) || 0);
    while (wsSendQueue.length > target && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    return wsSendQueue.length <= target;
  }

  return { wsEnqueue, resumeWsSendQueue, clearWsSendQueue, waitForQueueBelow };
}

// ── WS 心跳（防止 NAT/代理超时断连）──
function createWsHeartbeat(getWs, getSessionId) {
  let wsHeartbeatTimer = null;
  const WS_HEARTBEAT_MS = 25000;

  function startWsHeartbeat() {
    stopWsHeartbeat();
    wsHeartbeatTimer = setInterval(() => {
      const ws = getWs();
      if (ws && ws.readyState === 1) {  // WebSocket.OPEN
        try {
          ws.send(JSON.stringify({ type: 'heartbeat', session_id: getSessionId() }));
        } catch (e) {
          console.error('[serein] WS heartbeat 发送失败:', e?.message?.slice(0, 80) || e);
        }
      }
    }, WS_HEARTBEAT_MS);
  }

  function stopWsHeartbeat() {
    if (wsHeartbeatTimer) {
      clearInterval(wsHeartbeatTimer);
      wsHeartbeatTimer = null;
    }
  }

  return { startWsHeartbeat, stopWsHeartbeat };
}

export { createWsSendQueue, createWsHeartbeat };
