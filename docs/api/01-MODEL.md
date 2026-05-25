Xymon monitoring — domain model
===============================

One pipeline, two controls, two planes. This is the model the API is built on
(see openapi.yaml). It is intentionally small: 5 nouns + 2 controls.


The pipeline
------------
```
Host  ──run──▶  Test  ──produces──▶  State  ──raises──▶  Alarm  ──triggers──▶  Action
```

Every arrow obeys one law:

    advance if a RULE matches  —  unless a SUPPRESSION holds.

- **Rule**        — "when «condition», advance."   (state=red → raise Alarm;
                     alarm=critical → notify on-call)
- **Suppression** — "for «scope» during «window», hold."  (disable, maintenance,
                     dependency, ack-stops-notifying)
- both scoped by a **Selector** — a label/query over hosts & tests. A
  "service", "group", or "page" is just a Selector, not a container.


Two planes
----------
Defined (you write; mutable config):
  Host          a monitored thing
  Test          a check applied to hosts (via Selector)
  Rule          a condition that advances a transition
  Suppression   a scope+window that holds a transition

Observed (the system writes; timestamped; read-only):
  State         a test's current + historical result (color + measurements)
  Alarm         a raised incident; lifecycle: firing → acked → resolved
  Action        something done — auto (notify) or operator (ack/disable);
                carries an actor

The Defined/Observed split is what gives us config-vs-runtime and time/history
for free: observed entities are series (State) and events (Alarm, Action).


The one elegant link
--------------------
Operator commands are just Actions whose effect is a Suppression:

  acknowledge = Action{type: ack}     → Suppression on  Alarm → Action
  disable     = Action{type: disable} → Suppression on  Test  → State/Alarm

So `Action` is the single sink ("what was done, by whom"), `Suppression` is the
single gate, and they link. There are no bespoke ack/disable/enable verbs;
"enable" is just letting a Suppression expire or deleting it.


How everything maps
-------------------
  view the board        GET   /states?selector=…           (or /alarms for incidents)
  a host reports in     a Test produces/updates a State     (ingest)
  raise an alert        a Rule turns State into an Alarm
  send a notification   an Action triggered by an Alarm per a Rule
  acknowledge           POST  /actions {type:ack, alarm:…}  → Suppression
  disable / maintenance POST  /suppressions {selector, window}
  dependency suppress   a Suppression keyed on another host's State


How the API falls out (uniform)
-------------------------------
Each noun is a resource collection with the same shape; the plane decides which
methods are real:

  Defined   /hosts /tests /rules /suppressions
            GET (list, filter by selector) · GET/PUT/PATCH/DELETE (item)

  Observed  /states /alarms /actions
            GET (list, filter by selector) · GET (item)
            writes only via real commands: POST /actions (ack/disable),
            and State ingest (the wire protocol, or POST /states)

Filtering, projection (`fields`), and Selector are the same on every
collection. Differences between collections live in their record schema — data,
not API structure.


Properties
----------
- Orthogonal : each noun does one job; the same Rule/Suppression law governs
               every transition; one scoping mechanism (Selector); one error
               shape; uniform collection/item resources.
- Complete   : closes the gaps — Rule owns State→Alarm (+severity); Suppression
               is the single home for disable/maintenance/dependency/ack;
               planes give config-vs-runtime and time; Selector gives grouping.
- Symmetric  : every transition = Rule − Suppression. No special cases, no
               backward arrows (suppression is a declarative gate, not feedback).


Deferred (promote only on demand)
---------------------------------
- Metric / time-series : folded into State's measurements for now; promote to a
                         first-class entity if graphing/trends require it.
- Service              : a named Selector for now; promote to an entity if it
                         needs its own objects (ownership, SLOs).
