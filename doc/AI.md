<!--
File: redmine_mirror/doc/AI.md

Redmine Mirror - modular project import and asynchronous replication.
SPDX-License-Identifier: GPL-2.0-or-later

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the
Free Software Foundation, either version 2 of the License, or (at your
option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See LICENSE for details.

Document Mirror setup, operation, extension points or validation evidence.
-->

# AI usage

Mirror can ask an AI model to propose correspondences for long mapping lists, for
example 30 source statuses: *Nouveau* → *New*, *En recette* → *Testing*. This page sets
how Mirror uses AI. Each rule is enforced by the code and covered by the tests
(`test/ai_test.rb`, `test/unit/ai_suggestions_test.rb`, `test/integration/mirror_ai_test.rb`).

## Rules

1. **Off by default.** Only a Redmine administrator enables it, for the whole instance,
   in **Administration → Mirror → AI**.
2. **On demand only.** Nothing is sent automatically. A person who configures Mirror in
   the project clicks **Propose with AI** under one mapping table. The button appears
   only when the table has enough references without correspondence (10 by default):
   fewer are quicker to map by hand.
3. **AI proposes, a person decides.** A proposal only preselects a value in the form.
   Nothing is saved until a person saves the form, and the saved value goes through the
   usual validation. AI never runs a preview or a synchronization, and never writes to
   Redmine.
4. **Names only.** Mirror sends reference names and IDs, never project content (see
   [Data sent](#data-sent)). User names need a separate administrator option.
5. **Within a budget.** The administrator sets a daily request limit for the instance.
   When the provider refuses a request (quota or credit exhausted, key refused), Mirror
   pauses AI until an administrator tests the connection again.
6. **Closed answers.** The model can only choose among the IDs it was sent. Mirror drops
   any other ID, and any proposal below 50 % confidence.
7. **Visible and traceable.** Each proposal shows *proposed by AI* and its confidence.
   The form names the model, the API host and the time. The administration page shows
   the requests and tokens of the last 30 days.
8. **Fail-safe.** If the AI fails, the error is shown above the mappings. The forms, the
   same-name proposals and the runs keep working.

## Data sent

| Reference | Sent when a person clicks **Propose with AI** |
| --- | --- |
| Trackers, statuses, priorities, activities, custom fields, roles, groups, document categories | Source names and IDs of the references the project uses that have no correspondence yet; names and IDs of the local candidates of the form |
| Users | Only with **Also send user names**: source user names, and the names of the local candidates (no login or email) |

Mirror never sends issue subjects or descriptions, notes, time entries, wiki pages,
documents, attachments, logins, email addresses, Redmine URLs or API keys. Each request
also carries the model name, the reference type (`status`, `user`…) and fixed
instructions (`RedmineMirror::Ai::Suggester::INSTRUCTIONS`).

Names can still be sensitive: a custom field or a group can be named after a customer,
and user names are personal data. Before using a hosted API, check its terms: some free
tiers use requests to improve their models. A local model (Ollama) keeps everything on
your network.

## Setup

**Administration → Mirror → AI**:

| Setting | Value |
| --- | --- |
| Enable AI proposals | Checked |
| Provider | Google Gemini, Ollama (local), or another OpenAI-compatible API with its URL |
| API key | Write-only: encrypted with `database_cipher_key`, never shown again |
| Model | Chosen in the list given by **Test the connection and list the models** |
| Requests per day | For the whole instance, 50 by default; each request handles up to 50 references |
| Offer AI from | References without correspondence a table needs for the button, 10 by default |
| Also send user names | Unchecked unless you accept rule 4 for users |

**Test the connection and list the models** reads the provider's model list: it checks
the key without spending credit, and lifts a pause. Light models come first and are
marked *recommended*: matching names needs no large model, and a light one costs less.

![AI settings](screenshots/configuration/32-ai-settings.png)

With **Gemini**, create a key in Google AI Studio, then choose a *Flash-Lite* model. With
**Ollama**, pull a model on the host (`ollama pull llama3.1`): no key is needed.

The worker runs the requests. Its environment can also hold:

| Variable | Use |
| --- | --- |
| `MIRROR_AI_API_KEY` | Replaces the saved key, for those who keep secrets out of the database |
| `MIRROR_AI_TIMEOUT` | Read timeout in seconds, 120 by default; raise it for a slow local model |

The API URL must use HTTPS, or HTTP to `localhost`, a host name without a dot (a
container name) or a loopback or private IP address. Mirror does not follow redirects
and never shows or logs the API's response.

## How it works

1. In a mapping tab, under a table with enough references without correspondence, the
   button tells how many references would be sent, the number of requests, and the
   requests left today.
2. Clicking it queues the request; the worker runs it on its next pass (usually within a
   minute), as the person who asked, so the candidates are those of their form. The page
   refreshes by itself.
3. Mirror leaves out the references already mapped, those the project does not use, those
   with a single local namesake (case, accents, punctuation and word order ignored) and
   those already sent: a reference the AI found no match for is not sent again.
4. It sends the rest in batches of 50. For long local lists (over 50 candidates, typically
   users), each source reference comes only with its 10 closest local names.
5. The proposals are kept with the source references, also after a refresh. The form
   preselects them in yellow: a saved mapping comes first, then a same-name proposal,
   then the AI proposal.

![Propose with AI](screenshots/configuration/33-ai-offer.png)

![AI proposals](screenshots/configuration/34-ai-proposals.png)

## Credit

AI providers do not tell how much credit or quota is left: Gemini has no such API, and
reports an exhausted quota or spending limit with HTTP 429 when a request is made.
Mirror therefore:

- checks the key for free when the administrator tests the connection;
- checks its own daily limit before each request, and counts requests and tokens;
- stops at the first refusal (HTTP 402 or 429: quota or credit; 401 or 403: key), pauses
  AI for everyone and shows the reason. There is no automatic retry.

Watch the provider's own limits and billing as well: in Google AI Studio for Gemini.

## Security

Source names come from another Redmine and may contain text written to mislead the
model. At worst, it makes a wrong proposal: the model can only answer with IDs it was
sent, and a person checks each proposal before saving. The key is encrypted like the
source API keys, never shown again, and never sent anywhere but the configured API.

## Limits

- Custom field list values are not proposed yet.
- Proposal quality depends on the model. Small local models may miss translations or
  propose wrong matches with high confidence: always check.
