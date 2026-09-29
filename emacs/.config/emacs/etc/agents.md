# Coding Standards

Personal defaults. A repository's own AGENTS.md, CLAUDE.md or conventions win on conflict. Apply in the project's language. Examples are JavaScript. Don't reformat untouched code.

## Scope

- Change only what the task needs. No drive-by cleanup or unrequested options.
- Minimum code. No abstractions, helpers or config for one-time use or hypothetical needs.
- Reuse helpers from the codebase and standard library before writing new ones.
- Match surrounding patterns and naming.
- Delete replaced code. No shims, compat layers or legacy branches unless asked.
- Remove code your change made unused. Mention other dead code; don't delete it.

## Code

- Readable on first read. Name values after what they mean; no `data`, `res`, `tmp`, or one-letter names outside tiny callbacks.
- Name intermediate values the expression doesn't explain: `[0]`, cryptic keys, deep access, inline filters.

  ```javascript
  // bad
  sendInvoice(res.body.items.filter((i) => !i.refunded), res.body.meta.cust.email);
  // good
  const billableItems = order.items.filter((item) => !item.refunded);
  const customerEmail = order.meta.cust.email;
  sendInvoice(billableItems, customerEmail);
  ```

- Early returns over nested conditionals.
- Ternaries for simple if/else.
- Short arrow functions for callbacks.
- Interpolation (template literals, f-strings, `sprintf`) over more than two concatenations.
- Alphabetize object and map keys.
- Only builders and config objects return `this` for chaining. Elsewhere pass data through arguments and return values, not instance state.
- Order methods by visibility (public, protected, private); within each, abstract, static, then the rest. Public alphabetical; others in order of first call.
- CSS colors come from the project's color variables. New ones get a comment saying where they're used.

## Errors

- Fail loudly. Catch only to handle, or to add context and rethrow.
- No fallbacks or defaults that make a failure look like success. Default only when a value is genuinely optional.
- Validate at system boundaries. Trust internal code.
- Fix type errors; don't silence them with casts, `any` or suppressions.

```javascript
// bad
try { return (await db.plans.findByUser(id)) ?? 'free'; } catch { return 'free'; }
// good
const plan = await db.plans.findByUser(id);
if (!plan) throw new Error(`No plan for user ${id}`);
```

## Tests

- Production code never knows it's under test. The only concession: widening visibility to mock.
- Don't edit tests or hard-code values to pass. If a test looks wrong, say so.
- Tests must be able to fail. Test behavior, not mocks.

## No Explanations

Never explain or justify in comments, commits, PRs or docs. State the fact or the change, and stop. Explanations for the user go in your reply.

- Exception: a reason without which a reader would undo the change. State it as a short fact.
- No clauses starting with "because", "so that", "to ensure", "in order to", "since", "which means", "this way".

```text
bad:  // handle this gracefully, so that failures never break the frontend
good: // handle errors gracefully

bad:  Retry on 503, because the upstream drops connections during deploys.
good: Retry 503s on upstream connection drops

bad:  // use fetch instead of axios, which means one less dependency
good: (no comment)

exception: // Safari fires resize twice on rotation
```

## Comments

- Only for facts the code can't show: constraints, gotchas, workarounds, units. One short line. Delete by default.
- No narrating code, restating names, or `// end if` markers.
- Describe the code as it is, never how it got there. If a comment wouldn't make sense had the code always been this way, delete it ("fixed", "now uses", "instead of axios", "removed after the migration").
- Nothing that needs the task or conversation to make sense. No pointers to things that move, like spec sections.
- Every file, class and method gets a doc comment stating the contract (params, return, throws), not a restatement of the signature. Third person ("Creates", not "Create"). Use `@inheritdoc` on implementations of documented interfaces.
- TODOs reference a tracker issue. Resolve the ones for your change before review.
- Update docs a change makes wrong.

## Writing

Covers commits, PRs, docs, error and log messages.

- Fewest words. State behavior, not files touched.
- Plain words: "is", not "serves as". No robust, seamless, comprehensive, production-ready, leverage, delve, crucial, enhance.
- No emoji, decorative bold, "not X, but Y", or heavy em dashes.
- Bullets only for real lists. No "Additionally", "Furthermore".
- No attribution trailers ("Co-Authored-By", "Generated with").
- Claim only what you verified. Say when tests weren't run.
- Error and log messages include the ID, path or URL needed to act.

## Replies

- Very concise. Lead with the answer.
- No preamble, restating the question or closing summary.
- Only what the user needs to act or decide. They'll ask for more.
