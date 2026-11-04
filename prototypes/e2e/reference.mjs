// Reference scenario, written against the official JS client.
// Every prototype ports this exact scenario.
import { chromium } from 'playwright';
import { expect } from 'playwright/test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const fixtures = path.join(path.dirname(new URL(import.meta.url).pathname), 'fixtures');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pw-e2e-'));
const upload = path.join(tmp, 'notes.txt');
fs.writeFileSync(upload, 'hello upload');

const browser = await chromium.launch();
const context = await browser.newContext();
const page = await context.newPage();

// Navigation
await page.goto(pathToFileURL(path.join(fixtures, 'form.html')).href);
await expect(page).toHaveTitle('Sign up');

// Form + file upload
await page.getByLabel('Name').fill('Ada');
await page.getByLabel('Color').selectOption('blue');
await page.getByLabel('I agree').check();
await expect(page.getByLabel('I agree')).toBeChecked();
await page.getByLabel('Attachment').setInputFiles(upload);
await expect(page.locator('#file-info')).toHaveText('notes.txt (12 bytes)');

// Submit -> navigation
await page.getByRole('button', { name: 'Submit' }).click();
await page.waitForURL(/result\.html/);
await expect(page).toHaveURL(/name=Ada/);
await expect(page.getByTestId('greeting')).toHaveText('Hello, Ada (blue)');

// Window handling
const popupPromise = page.waitForEvent('popup');
await page.getByRole('link', { name: 'Open details' }).click();
const popup = await popupPromise;
await popup.waitForLoadState();
await expect(popup.locator('h1')).toHaveText('Details');
if (context.pages().length !== 2) throw new Error('expected 2 pages');
await popup.close();
if (context.pages().length !== 1) throw new Error('expected 1 page');

// Downloads
const downloadPromise = page.waitForEvent('download');
await page.getByRole('link', { name: 'Download report' }).click();
const download = await downloadPromise;
if (download.suggestedFilename() !== 'report.csv') throw new Error('bad filename');
const saved = path.join(tmp, 'out', 'report.csv');
await download.saveAs(saved);
if (fs.readFileSync(saved, 'utf8') !== 'a,b\n1,2') throw new Error('bad download content');

await browser.close();
console.log('reference e2e: OK');
