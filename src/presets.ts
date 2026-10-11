import definitions from "../assets/block-presets.json";

export interface Preset {
  name: string;
  title: string;
  icon: string;
  domains: string[];
}

const withWww = (domains: string[]): string[] => domains.flatMap((domain) => [domain, `www.${domain}`]);

export const presets: Preset[] = definitions.map((preset) => ({ ...preset, domains: withWww(preset.domains) }));

export function getPreset(name: string): Preset | undefined {
  return presets.find((preset) => preset.name === name);
}
