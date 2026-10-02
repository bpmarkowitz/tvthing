// Free live channels that broadcasters publish themselves, plus one test stream. The first
// four play without FFmpeg, so a fresh install's buttons work right away.

import type { Channel } from './library';

const hls = (name: string, url: string): Omit<Channel, 'id'> => ({ name, source: { provider: 'hls', value: url } });

export const STARTER_CHANNELS: Omit<Channel, 'id'>[] = [
  hls('Al Jazeera English', 'https://live-hls-apps-aje-fa.getaj.net/AJE/index.m3u8'),
  hls('Red Bull TV', 'https://rbmn-live.akamaized.net/hls/live/590964/BoRB-AT/master.m3u8'),
  hls('PBS Kids', 'https://livestream.pbskids.org/out/v1/14507d931bbe48a69287e4850e53443c/est.m3u8'),
  hls('Africanews', 'https://cdn-euronews.akamaized.net/live/eds/africanews-en/25049/index.m3u8'),
  hls('CBS News Miami', 'https://cbsn-mia.cbsnstream.cbsnews.com/out/v1/ac174b7938264d24ae27e56f6584bca0/master.m3u8'),
  hls('Bloomberg Originals', 'https://bloomberg.com/media-manifest/streams/qt.m3u8'),
  hls('France 24 English', 'https://live.france24.com/hls/live/2037218-b/F24_EN_HI_HLS/master_5000.m3u8'),
  hls('DW English', 'https://dwamdstream102.akamaized.net/hls/live/2015525/dwstream102/master.m3u8'),
  hls('NHK World-Japan', 'https://masterpl.hls.nhkworld.jp/hls/w/live/smarttv.m3u8'),
  hls('Arirang TV', 'https://amdlive-ch01-ctnd-com.akamaized.net/arirang_1ch/smil:arirang_1ch.smil/playlist.m3u8'),
  hls('Fox Weather', 'https://247wlive.foxweather.com/stream/index.m3u8'),
  hls('Big Buck Bunny (test stream)', 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
];
