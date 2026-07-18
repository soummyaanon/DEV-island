import type { FastifyInstance } from "fastify";
import type { WireMessage } from "@agent-island/shared";
import type { EventHub } from "../hub/event-hub";

/** WebSocket.OPEN — avoids importing ws just for the constant. */
const WS_OPEN = 1;

/**
 * `GET /stream` — subscribers get a snapshot on connect, then every event as it
 * arrives, plus periodic pings. Fastify + @fastify/websocket hands us the raw
 * ws socket directly (v11 signature).
 */
export function registerStreamRoute(app: FastifyInstance, hub: EventHub): void {
  app.get("/stream", { websocket: true }, (socket) => {
    const send = (message: WireMessage): void => {
      if (socket.readyState === WS_OPEN) {
        socket.send(JSON.stringify(message));
      }
    };

    const unsubscribe = hub.subscribe(send);
    socket.on("close", unsubscribe);
    socket.on("error", unsubscribe);
  });
}
