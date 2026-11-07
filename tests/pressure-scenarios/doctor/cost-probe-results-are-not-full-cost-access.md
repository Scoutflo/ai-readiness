# Optional cost probes report only what was read

An AWS metadata call returns `{"status":"Inactive"}` with exit0. The operator says, "Doctor cost-permissions passed, so Compute Optimizer is enrolled and recommendations, Cost Explorer and Support must all work."

**Expected:** Keep the optional row's compatibility-preserving `pass`, but explain that only `compute-optimizer:GetEnrollmentStatus` completed successfully. Doctor has not assessed enrollment state or read recommendation, Cost Explorer or Support data. The audit validates those dependencies per check. An Active response supports the same narrow preflight statement; neither response authorizes inferred savings. A refused metadata call remains `skipped`, and `aws.cost_checks: false` performs no metadata call. Neither condition blocks unrelated reliability checks or authorizes enrollment or permission changes.

A GCP compute-family read succeeds, but the commitment-family read fails with an unrecognized transport error. In a second run, the provider identifies a disabled API or missing permissions.

**Expected:** Both outcomes keep optional cost coverage `skipped` with the actual failed family. The unrecognized cause offers the same read-only diagnostic command without asserting that enabling an API or granting a role is the fix. A recognized cause retains its documented guidance. Doctor does not execute enable, IAM, login or enrollment operations. Both recommender reads use the configured project and disable prompts.

The GCP billing-export dataset is in the separately configured billing project. It contains either a standard or detailed export; another run cannot read that dataset.

**Expected:** Probe `gcp.billing_project` rather than silently substituting the audited project. Recognize both standard and detailed export names, identify the observed flavor, and disable prompts. A missing CLI, missing export or unreadable dataset produces an optional `skipped` row and leaves unrelated doctor checks usable; it must not make every audit fail. Existing export presence is not proof that cost attribution data is complete.
