import { defineConfig, devices } from '@playwright/test';

const port = required('SYNAPSE_LIVE_UI_PORT');
const outputDir = required('SYNAPSE_LIVE_OUTPUT');

export default defineConfig({
  testDir: './tests/live',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: 'list',
  outputDir,
  use: {
    baseURL: `http://127.0.0.1:${port}`,
    trace: 'off',
    screenshot: 'off',
    video: 'off',
  },
  projects: [{ name: 'live-tokamak-chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: {
    command: `npm run preview -- --host 127.0.0.1 --port ${port}`,
    url: `http://127.0.0.1:${port}`,
    reuseExistingServer: false,
  },
});

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required by the external live owner`);
  return value;
}
