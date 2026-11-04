// Port of upstream utils/protocol_spec.js#loadProtocol: merges packages/protocol/spec/*.yml
// into one JSON object on stdout. Uses the yaml parser bundled in playwright-core, so no npm install.
// Usage: node protocol_to_json.js <playwright-js-repo> <path/to/playwright-core>
const fs = require('fs');
const path = require('path');
const { yaml } = require(path.join(path.resolve(process.argv[3]), 'lib', 'utilsBundle.js'));

const specDir = path.join(process.argv[2], 'packages', 'protocol', 'spec');
const protocol = {};
for (const file of fs.readdirSync(specDir).filter(f => f.endsWith('.yml')).sort()) {
  const doc = yaml.parse(fs.readFileSync(path.join(specDir, file), 'utf-8'));
  for (const [name, value] of Object.entries(doc)) {
    if (name in protocol)
      throw new Error(`Duplicate top-level definition "${name}" in ${file}`);
    protocol[name] = value;
  }
}
process.stdout.write(JSON.stringify(protocol));
