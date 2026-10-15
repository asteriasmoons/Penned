import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

// Bundle Apple's symbol names/metadata only. Glyphs are rendered by public system-image APIs.
const source = process.argv[2] || "/Applications/SF Symbols.app/Contents/Resources/Metadata";
const plist = name => JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", resolve(source, name)], { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 }));
const availability = plist("name_availability.plist"), categories = plist("categories.plist");
const assignments = plist("symbol_categories.plist"), search = plist("symbol_search.plist"), aliases = plist("name_aliases.strings");
const variants = JSON.parse(readFileSync(resolve(source, "base_symbols_map.json"), "utf8"));
const baseNames = new Map(Object.entries(variants).flatMap(([base, names]) => names.map(name => [name, base])));
const symbols = Object.entries(availability.symbols).sort(([a], [b]) => a.localeCompare(b)).map(([name, year]) => {
  const canonical = aliases[name] || name, base = baseNames.get(canonical) || canonical;
  const assigned = assignments[name] || assignments[canonical] || assignments[base] || [];
  return { name, categories: assigned, releases: availability.year_to_release[year] || {}, keywords: search[name] || search[canonical] || search[base] || [] };
});
if (symbols.length < 7000) throw new Error("Incomplete SF Symbols metadata; refusing to replace the catalog.");
const catalog = { source: "Apple SF Symbols.app metadata", count: symbols.length,
  categories: categories.map(c => ({ id: c.key, name: c.label.replaceAll("\u2019", "'"), icon: c.icon })), symbols };
const target = fileURLToPath(new URL("../Vellix/Resources/SFSymbolCatalog.json", import.meta.url));
writeFileSync(target, JSON.stringify(catalog));
console.log(`Bundled ${symbols.length} SF Symbols names and ${categories.length} Apple categories: ${target}`);
