import path from 'node:path';

// Old and new Rex inventory readers enumerate only top-level *.json receipts.
// Protocol messages are not receipts, including during a mixed-version rollout.
export function reviewerRetirementPaths(receipt) {
  const directory = `${receipt}.retirement`;
  return {
    directory,
    capability: path.join(directory, 'capability.json'),
    request: path.join(directory, 'request.json'),
    response: path.join(directory, 'response.json'),
  };
}
