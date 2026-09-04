declare module 'node:fs/promises' {
  export function readFile(path: string, encoding: 'utf8'): Promise<string>
}

declare const process: {
  env: Record<string, string | undefined>
}
