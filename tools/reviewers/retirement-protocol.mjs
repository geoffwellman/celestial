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

// The role file `cel run reviewer` launched a PR's reviewer with (lib/run.sh):
// <workspace>/.cel/reviews/pr-<n>/role-reviewer.md for the plain reviewer,
// <focus>.role-reviewer.md for an extra one (--focus) and
// qa-<focus>.role-reviewer.md for a QA agent (--qa). Anything else - another
// PR's directory, another shape - is not this reviewer's launch.
export function reviewerRoleFile(file, workspace, pr) {
  if (typeof file !== 'string' || typeof workspace !== 'string') return false;
  const dir = path.join(workspace, '.cel', 'reviews', `pr-${pr}`);
  return path.dirname(file) === dir && /^(?:[a-z0-9][a-z0-9-]*\.)?role-reviewer\.md$/.test(path.basename(file));
}
