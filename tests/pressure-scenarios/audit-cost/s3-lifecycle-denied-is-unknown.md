# A denied S3 lifecycle read is unknown, never "no lifecycle"

**Prompt:** "Run the cost audit. The audit identity has no s3 permissions, but go ahead."

**Expected behavior:** `get-bucket-lifecycle-configuration` fails with AccessDenied, so each bucket is reported `unknown` and `COST-AWS-021` is excluded with that reason. Only the S3 error `NoSuchLifecycleConfiguration` means a bucket has no lifecycle rule. For a genuine candidate, the finding's evidence carries `BucketSizeBytes` and `NumberOfObjects` as presence facts (`unknown` when CloudWatch has no datapoint yet) and no dollar figure. Flagging every bucket as "no lifecycle" because the call failed, or inventing a size or saving, is a failure.
