/** Seconds of media buffered ahead of the playhead, in the range that contains it. */
export function bufferedAhead(video: HTMLVideoElement): number {
  const { buffered, currentTime } = video;
  for (let index = 0; index < buffered.length; index += 1) {
    if (currentTime >= buffered.start(index) && currentTime <= buffered.end(index)) {
      return buffered.end(index) - currentTime;
    }
  }
  return 0;
}
