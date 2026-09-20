- console: the subscription edge is on all five status rows, not one. Four
  renderers called `statusRow` without the fleet document, so the usage the
  owner asked for was absent from the services, unit, worker and timeline
  views; the width now reaches `subsEdge` too, so the bar is actually drawn.
  `statusRow` refuses a missing document instead of rendering an empty edge.
