import { createReadStream } from 'node:fs';
import { createInterface } from 'node:readline';

export async function forEachJsonlLine(
  filePath: string,
  onLine: (line: string, lineIndex: number) => void | Promise<void>,
): Promise<void> {
  const stream = createReadStream(filePath, { encoding: 'utf8' });
  const rl = createInterface({ input: stream, crlfDelay: Infinity });
  let index = 0;
  for await (const line of rl) {
    const trimmed = line.trim();
    if (!trimmed) {
      continue;
    }
    await onLine(trimmed, index);
    index += 1;
  }
}
