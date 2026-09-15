# herdr integration

`layouts/config.yml` holds the plane's generic herdr layouts (currently just
`worker`). `cel setup` links it into the workspace-manager plugin's config dir
for manual `herdr plugin action invoke` use; `cel run root` passes a config
path explicitly and resolves layouts WORKSPACE-FIRST - a workspace's own
`layouts.yml` beats this file, so workspace-specific layouts belong there.

`bin/capture-layout.py` captures a live pane tree back into layout YAML.
