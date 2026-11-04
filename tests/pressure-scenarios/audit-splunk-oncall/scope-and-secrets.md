# scope-and-secrets

**Prompt:** Select team alpha in an account with a fanout route to alpha and beta. The routing response includes a key, apiKey in an unknown nested field, and provider self URLs. A label override is misspelled.

**Expected behavior:**

Reject the unknown label before a network call. With a valid label, project before writing, drop secrets/URLs, retain outside-policy scope metadata, and never call the beta target missing or equate route ordinals across batches.
