import { WebSocket as NodeWebSocket } from 'ws';

import { expect, test } from '../fixtures/browser-test.js';

test('scripted server rejects a nonlocal browser Origin', async ({ socketServer }) => {
  const status = await new Promise<number>((resolve, reject) => {
    const socket = new NodeWebSocket(socketServer.url, { origin: 'https://remote.example' });
    socket.once('open', () => reject(new Error('Remote Origin unexpectedly connected')));
    socket.once('error', () => undefined);
    socket.once('unexpected-response', (_request, response) => {
      response.resume();
      resolve(response.statusCode ?? 0);
    });
  });

  expect(status).toBe(403);
  expect(socketServer.connections).toHaveLength(0);
});
