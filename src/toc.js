// Parses a WoW .toc file: "## Key: Value" metadata and the file list in load order.

export function parseToc(text) {
  const metadata = {};
  const files = [];
  for (let raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    const meta = line.match(/^##\s*([^:]+?)\s*:\s*(.*)$/);
    if (meta) {
      metadata[meta[1]] = meta[2];
      continue;
    }
    if (line.startsWith("#")) continue;
    // Strip client directives like "[AllowLoadGameType mainline]" (not evaluated: Retail only).
    const file = line.replace(/\s*\[[^\]]*\]\s*/g, "").trim();
    if (file) files.push(file.replace(/\\/g, "/"));
  }
  return { metadata, files };
}

// "SavedVariables" + "SavedVariablesPerCharacter" names, comma separated.
export function savedVariableNames(metadata) {
  return [metadata.SavedVariables, metadata.SavedVariablesPerCharacter]
    .filter(Boolean).join(",");
}
