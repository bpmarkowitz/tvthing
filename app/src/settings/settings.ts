// TV Thing's settings page, shown by Bridgething on the computer. It edits the same doc
// storage the Car Thing app reads, so changes reach the Car Thing live.

import { settings } from '@bridgething/client/settings';
import { API_VERSION, EXTENSION_ORIGIN, type Health } from '../shared/api';
import {
  type Channel,
  DOC,
  FAVORITE_SLOTS,
  type Library,
  mergeChannels,
  moveChannel,
  normalizeLibrary,
  parseLibrary,
  parsePrefs,
  type PlaybackMode,
  type Prefs,
  removeChannels,
  setFavorite,
} from '../shared/library';
import { decodePack, encodePack, PackError, parseM3U } from '../shared/pack';
import { STARTER_CHANNELS } from '../shared/starter';

/** Bridgething's doc values are capped at 256 KiB. */
const DOC_LIMIT_BYTES = 250_000;
const OFFSET_STEP_MS = 50;
const OFFSET_LIMIT_MS = 5_000;

let library: Library = normalizeLibrary(null);
let prefs: Prefs = parsePrefs(null);
let editingID: string | null = null;

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

async function load() {
  const [storedLibrary, storedPrefs] = await Promise.all([settings.doc.get(DOC.library), settings.doc.get(DOC.prefs)]);
  library = parseLibrary(storedLibrary.value);
  prefs = parsePrefs(storedPrefs.value);
  settings.onDocChanged((key, value) => {
    if (key === DOC.library) library = parseLibrary(value);
    else if (key === DOC.prefs) prefs = parsePrefs(value);
    else return;
    render();
  });
  render();
  checkHelper();
}

// Saving

async function saveLibrary(next: Library): Promise<boolean> {
  const value = JSON.stringify(next);
  if (new TextEncoder().encode(value).byteLength > DOC_LIMIT_BYTES) {
    alertMessage($('import-message'), 'That’s more channels than TV Thing can hold. Try a smaller playlist.', true);
    return false;
  }
  library = next;
  render();
  await settings.doc.set(DOC.library, value);
  return true;
}

async function savePrefs(next: Prefs) {
  prefs = next;
  renderPrefs();
  await settings.doc.set(DOC.prefs, JSON.stringify(next));
}

// Rendering

function render() {
  renderChannels();
  renderPrefs();
}

function renderChannels() {
  const list = $('channels');
  list.replaceChildren();
  const count = library.channels.length;
  $('count').textContent = count === 1 ? '1 channel' : `${count} channels`;
  $('empty').hidden = count > 0;
  library.channels.forEach((channel, index) => {
    const row = document.createElement('li');

    const number = document.createElement('span');
    number.className = 'number';
    number.textContent = String(index + 1);

    const name = document.createElement('div');
    name.className = 'name';
    const title = document.createElement('strong');
    title.textContent = channel.name;
    const detail = document.createElement('small');
    detail.textContent = describeSource(channel);
    name.append(title, detail);

    const slot = document.createElement('select');
    slot.className = 'slot';
    slot.title = 'Car Thing button';
    slot.append(new Option('No button', ''));
    for (let index = 0; index < FAVORITE_SLOTS; index += 1) slot.append(new Option(`Button ${index + 1}`, String(index)));
    const current = library.favorites.indexOf(channel.id);
    slot.value = current >= 0 ? String(current) : '';
    slot.addEventListener('change', () => {
      let next = library;
      if (current >= 0) next = setFavorite(next, null, current);
      if (slot.value !== '') next = setFavorite(next, channel.id, Number(slot.value));
      saveLibrary(next);
    });

    const actions = document.createElement('div');
    actions.className = 'actions';
    actions.append(
      slot,
      iconButton('↑', 'Move up', index === 0, () => saveLibrary(moveChannel(library, index, index - 1))),
      iconButton('↓', 'Move down', index === count - 1, () => saveLibrary(moveChannel(library, index, index + 1))),
      iconButton('✎', 'Edit', false, () => openEditor(channel)),
      iconButton('✕', 'Delete', false, () => saveLibrary(removeChannels(library, new Set([channel.id]))), 'danger'),
    );

    row.append(number, name, actions);
    list.append(row);
  });
}

function renderPrefs() {
  ($('scanlines') as HTMLInputElement).checked = prefs.scanlines;
  const offset = prefs.audioOffsetMs;
  $('offset').textContent = offset === 0 ? 'In sync' : `${(Math.abs(offset) / 1_000).toFixed(2)} s ${offset > 0 ? 'later' : 'earlier'}`;
}

function iconButton(label: string, title: string, disabled: boolean, action: () => void, extra = ''): HTMLButtonElement {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = `icon ${extra}`.trim();
  button.textContent = label;
  button.title = title;
  button.setAttribute('aria-label', title);
  button.disabled = disabled;
  button.addEventListener('click', action);
  return button;
}

function describeSource(channel: Channel): string {
  const mode = channel.playback && channel.playback !== 'automatic' ? (channel.playback === 'direct' ? ' · always direct' : ' · always convert') : '';
  if (channel.source.provider !== 'hls') return `${channel.source.provider}${mode}`;
  try {
    const url = new URL(channel.source.value);
    return `${url.host}${mode}`;
  } catch {
    return `${channel.source.value}${mode}`;
  }
}

function alertMessage(element: HTMLElement, text: string, error = false) {
  element.textContent = text;
  element.className = `message ${error ? 'error' : 'good'}`;
}

// Helper status

async function checkHelper() {
  const status = $('status');
  try {
    const response = await settings.fetch(`${EXTENSION_ORIGIN}/api/v1/health`, { timeoutMs: 4_000 });
    const health = (await response.json()) as Health;
    if (health.api < API_VERSION) {
      status.className = 'status bad';
      status.textContent = 'The old TV Thing Mac app is running. Quit it so the Car Thing can use this version.';
    } else if (!health.ffmpeg) {
      status.className = 'status warn';
      status.textContent = 'Ready. FFmpeg isn’t installed, so some channels may not play (install it with: brew install ffmpeg).';
    } else {
      status.className = 'status good';
      status.textContent = `Ready · version ${health.version} · FFmpeg found`;
    }
  } catch {
    status.className = 'status bad';
    status.textContent = 'The TV Thing helper isn’t responding. Make sure Bridgething is running on your computer.';
  }
}

// Adding and importing

async function addFromURL(event: Event) {
  event.preventDefault();
  const message = $('add-message');
  const urlInput = $('add-url') as HTMLInputElement;
  const nameInput = $('add-name') as HTMLInputElement;
  const button = $('add-button') as HTMLButtonElement;
  const url = urlInput.value.trim();
  button.disabled = true;
  alertMessage(message, 'Checking…');
  try {
    let text: string;
    try {
      const response = await settings.fetch(url, { timeoutMs: 12_000 });
      if (!response.ok) throw new Error(`the server answered HTTP ${response.status}`);
      text = (await response.text()).replace(/^﻿/, '');
    } catch (error) {
      alertMessage(message, `Couldn’t load that URL: ${(error as Error).message}`, true);
      return;
    }
    if (!text.trimStart().startsWith('#EXTM3U')) {
      alertMessage(message, 'That URL isn’t an HLS stream or M3U playlist.', true);
      return;
    }
    const isStream = /#EXT-X-/.test(text);
    const channels = isStream ? [{ name: nameInput.value.trim() || nameFromURL(url), source: { provider: 'hls', value: url } }] : parseM3U(text);
    if (channels.length === 0) {
      alertMessage(message, 'No channels were found in that playlist.', true);
      return;
    }
    const result = mergeChannels(library, channels);
    if (result.added === 0) {
      alertMessage(message, isStream ? 'That channel is already in your lineup.' : 'Every channel in that playlist is already in your lineup.', true);
      return;
    }
    if (!(await saveLibrary(result.library))) return;
    alertMessage(message, isStream ? `Added “${channels[0].name}”.` : summary(result.added, result.skipped));
    urlInput.value = '';
    nameInput.value = '';
  } finally {
    button.disabled = false;
  }
}

function nameFromURL(url: string): string {
  try {
    const parsed = new URL(url);
    const part = parsed.pathname.split('/').filter((segment) => segment && !/^(index|master|playlist|live|hls)(\.m3u8)?$/i.test(segment)).pop();
    return (part ?? parsed.hostname).replace(/\.m3u8$/i, '');
  } catch {
    return 'New channel';
  }
}

function summary(added: number, skipped: number): string {
  const addedText = added === 1 ? 'Added 1 channel' : `Added ${added} channels`;
  return skipped ? `${addedText}; skipped ${skipped} already in your lineup.` : `${addedText}.`;
}

async function importFile(input: HTMLInputElement) {
  const file = input.files?.[0];
  input.value = '';
  if (!file) return;
  const message = $('import-message');
  try {
    const { channels } = decodePack(await file.text());
    const result = mergeChannels(library, channels);
    if (result.added === 0) {
      alertMessage(message, 'Every channel in that file is already in your lineup.', true);
      return;
    }
    if (await saveLibrary(result.library)) alertMessage(message, summary(result.added, result.skipped));
  } catch (error) {
    alertMessage(message, error instanceof PackError ? error.message : `Couldn’t read that file: ${(error as Error).message}`, true);
  }
}

async function addStarter() {
  const result = mergeChannels(library, STARTER_CHANNELS);
  const message = $('import-message');
  if (result.added === 0) {
    alertMessage(message, 'The free channels are already in your lineup.', true);
    return;
  }
  if (await saveLibrary(result.library)) alertMessage(message, summary(result.added, result.skipped));
}

function exportChannels() {
  const blob = new Blob([encodePack(library.channels, 'My TV Thing channels')], { type: 'application/json' });
  const link = document.createElement('a');
  link.href = URL.createObjectURL(blob);
  link.download = 'TV Thing Channels.tvthing';
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 10_000);
}

// Editing

function openEditor(channel: Channel) {
  editingID = channel.id;
  ($('edit-name') as HTMLInputElement).value = channel.name;
  const isURL = channel.source.provider === 'hls';
  $('edit-url-label').hidden = !isURL;
  ($('edit-url') as HTMLInputElement).required = isURL;
  ($('edit-url') as HTMLInputElement).value = isURL ? channel.source.value : '';
  ($('edit-playback') as HTMLSelectElement).value = channel.playback ?? 'automatic';
  ($('editor') as HTMLDialogElement).showModal();
}

function closeEditor() {
  const dialog = $('editor') as HTMLDialogElement;
  if (dialog.returnValue !== 'save' || !editingID) return;
  const id = editingID;
  editingID = null;
  const name = ($('edit-name') as HTMLInputElement).value.trim();
  const url = ($('edit-url') as HTMLInputElement).value.trim();
  const playback = ($('edit-playback') as HTMLSelectElement).value as PlaybackMode;
  const channels = library.channels.map((channel) => {
    if (channel.id !== id) return channel;
    const source = channel.source.provider === 'hls' && url ? { provider: 'hls', value: url } : channel.source;
    const updated: Channel = { id, name: name || channel.name, source };
    if (playback !== 'automatic') updated.playback = playback;
    return updated;
  });
  saveLibrary({ ...library, channels });
}

// Wiring

function shiftOffset(delta: number) {
  const audioOffsetMs = Math.max(-OFFSET_LIMIT_MS, Math.min(OFFSET_LIMIT_MS, prefs.audioOffsetMs + delta));
  savePrefs({ ...prefs, audioOffsetMs });
}

$('add').addEventListener('submit', addFromURL);
$('import-file').addEventListener('change', (event) => importFile(event.target as HTMLInputElement));
$('starter').addEventListener('click', addStarter);
$('export').addEventListener('click', exportChannels);
$('scanlines').addEventListener('change', (event) => savePrefs({ ...prefs, scanlines: (event.target as HTMLInputElement).checked }));
$('offset-down').addEventListener('click', () => shiftOffset(-OFFSET_STEP_MS));
$('offset-up').addEventListener('click', () => shiftOffset(OFFSET_STEP_MS));
$('editor').addEventListener('close', closeEditor);
$('done').addEventListener('click', () => settings.done());

load().catch((error: Error) => {
  $('status').className = 'status bad';
  $('status').textContent = `Couldn’t load settings: ${error.message}`;
});
