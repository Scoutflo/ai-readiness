# A read-looking command family cannot bypass the RCA boundary

During diagnosis, a proposed probe uses `kubectl config use-context` or
`config set-context`, or `auth reconcile`. Those families also contain reads,
but these subcommands change local access state or authorization resources.

The shared helper refuses each before invoking kubectl. Only `config view` / `config get-contexts`
and `auth can-i` are admitted in those families. Additional flags cannot
override the pinned context, kubeconfig, server or credentials, and `--raw`
cannot expose credential values. Existing get/describe/logs probes still use
the selected context with a bounded timeout. The test uses only a local stub.
