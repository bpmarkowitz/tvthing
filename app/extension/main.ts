// TV Thing's Bridgething extension: runs on the computer beside the Car Thing app, relaying
// streams (and converting them with FFmpeg when needed) on a local port.
//
// `deno run -A dist/extension-dev.mjs` runs the same engine standalone for development.

import { defineExtension } from '@bridgething/extension';
import { Engine } from './engine/server';

declare const __APP_VERSION__: string;
declare const __STANDALONE__: boolean;

if (__STANDALONE__) {
  const port = Number(Deno.env.get('TVTHING_PORT')) || undefined;
  const engine = new Engine({ version: __APP_VERSION__, port, log: (line) => console.error(`[TV Thing] ${line}`) });
  await engine.start();
  Deno.addSignalListener('SIGINT', async () => {
    await engine.stop();
    Deno.exit(0);
  });
} else {
  let engine: Engine | null = null;
  defineExtension({
    async start(ctx) {
      engine = new Engine({ version: __APP_VERSION__, log: (line) => ctx.log.info(line) });
      await engine.start();
    },
    async stop() {
      await engine?.stop();
    },
  });
}
