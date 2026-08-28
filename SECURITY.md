# Security

Please report vulnerabilities privately through GitHub's security advisory form for `mozok-git/coder.nvim`. Do not open a public issue containing an unpatched exploit or sensitive repository data.

Coder treats model output as untrusted input. Patch paths must stay inside the selected workspace after symlink resolution, and OpenCode runs with its edit-restricted `plan` agent by default. The plan agent may retain shell access, and users can weaken its protections through OpenCode or Coder configuration.
