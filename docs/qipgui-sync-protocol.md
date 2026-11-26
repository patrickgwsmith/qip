# qipgui shared channel protocol

This protocol lets many `qipgui` clients run the same GUI component and show
the same confirmed state. An editor sends input with HTTP `POST`. The server
puts all input in one ordered log. The server sends the log to all clients
with Server-Sent Events (SSE). A viewer only reads the log.

The server is the only source of order and time. A client changes shared
state only when an entry arrives in the log. This rule also applies to the
editor that sent the input.

## Scope

Version 1 shares a QIP GUI component, its initial input, its key and
pointer events, and the wakes that it asks for. Each client runs its own copy of the WebAssembly module and
renders its own frames. The server does not run the module and does not send
images. The server can replace the module of an open channel.

Local presentation settings do not go into the log. Examples are terminal
size, image scale, and focus. Version 1 has no snapshots.

Use this protocol when all clients can load the same component and replay its
history. Do not use it for these components:

- A component whose state depends on client-local data.
- A component whose state depends on host behavior that is not deterministic.
- A component whose history is too long to replay in an acceptable time.

## Channel URLs

A client starts with a channel URL, for example
`https://sync.example.org/v1/channels/Rk3v...`. This protocol does not
specify how a channel is created or how the client gets its URL.

The last path segment of the URL is a capability. A capability is an opaque
value that is not possible to guess. It identifies the channel and gives
access to it. There is no other channel identifier. The paths in this
document show the capability as `{capability}`.

There are two types of capability:

- A read capability permits a client to read the log. A client with a read
  capability is a viewer.
- A write capability permits a client to read the log and to send input. A
  client with a write capability is an editor.

The URL uses HTTPS. For a test on one computer, a client can accept `http`
for a loopback address. A client must keep the URL secret. The server must not write
capabilities to its logs and must not put them in requests to third parties.

### Find the capability type

A capability is opaque, so a client cannot read its type from the URL. The
server tells the client the type with the HTTP `Allow` header
([RFC 9110, section 10.2.1](https://www.rfc-editor.org/rfc/rfc9110#section-10.2.1)).
The header lists the methods that the capability permits on
`/v1/channels/{capability}/events`:

| Capability                  | `Allow`     |
|-----------------------------|-------------|
| Read capability             | `GET`       |
| Write capability            | `GET, POST` |
| Either, on a closed channel | `GET`       |

The server sends `Allow` in these responses:

- The `200` response to the `GET` that opens the event stream. The header
  arrives before the first entry.
- The response to `HEAD /v1/channels/{capability}/events`. The server sends
  the same status and headers as the `GET` that opens the stream, but it
  does not send a body and does not register a stream
  ([RFC 9110, section 9.3.2](https://www.rfc-editor.org/rfc/rfc9110#section-9.3.2)).
- The `202`, `403`, and `410` responses to a `POST`.

The server does not send `Allow` in a `404` response, because there is no
channel to describe.

A user interface can send `HEAD` to find the capability type before it opens
the stream. For example, it can show an input control only for a write
capability. `HEAD` also gives the status, so a `404` shows that the channel
does not exist.

The server can also list other methods that it supports, such as `HEAD`. A
client uses only one fact from the header: whether `POST` is in the list. The
client splits the value at commas and removes spaces and tabs around each
method. Method names are case-sensitive, so `post` is not `POST`.

A client obeys these rules:

- If `Allow` does not list `POST`, the client is a viewer. It does not send
  input and does not ask the user for permission to send input.
- If `Allow` lists `POST`, the client is an editor. Before it sends input,
  it can ask the user, because every client on the channel receives that
  input.
- If the response has no `Allow` header, the type is not known. The client
  finds the type from the status of its first `POST`. `403` means a read
  capability.
- If a later response changes the value, the client uses the new value. For
  example, the `410` response after a channel closes has `Allow: GET`.

A browser client reads the header from a cross-origin response only if the
server exposes it. Such a server sends `Access-Control-Expose-Headers: Allow`.

## Log entries

The log is a sequence of entries. Each entry has a sequence number, `seq`.
The first entry has `seq` `0`. Each later `seq` is one more than the `seq`
before it.

Each entry is one SSE event:

- The `id` field is `seq` as a decimal number.
- The `event` field is the entry type.
- Each `data` line is one field line.

There are four entry types:

| `event`    | Function                                             |
|------------|------------------------------------------------------|
| `module`   | Start a module. Discard the module before it.        |
| `prefetch` | Tell the client that a module will possibly be used. |
| `update`   | Apply one batch of input at one time.                |
| `closed`   | End the channel.                                     |

The first entry in the log is always a `module` entry.

The server also sends `time` events. A `time` event is not a log entry. See
[The channel clock](#the-channel-clock).

### Field lines

A field line is a list of `name=value` pairs with `&` between them. It uses
the `application/x-www-form-urlencoded` format. `URLSearchParams` reads and
writes this format.

These rules apply to all field lines:

- The sender must percent-encode each value. A `+` that is not encoded
  becomes a space.
- A field line does not contain a line break.
- All values are text. The receiver must convert each value to its type.
- The receiver ignores a field name that it does not know.
- If a name occurs more than one time, the receiver uses the first value.

The fields have these types:

| Field                         | Type                                          |
|-------------------------------|-----------------------------------------------|
| `time_ms`                     | Decimal integer, `1` to the `i64` maximum     |
| `keysym`, `flags`, `mask`     | Decimal integer in the `i32` range            |
| `x`, `y`                      | Decimal integer in the `i32` range            |
| `seq`                         | Decimal integer, `0` or more                  |
| `update_id`                   | 1 to 64 characters from `A-Z a-z 0-9 - _`     |
| `type`                        | `key` or `pointer`                            |
| `url`                         | Absolute HTTPS URL                            |
| `integrity`                   | `sha256-` and then the base64 SHA-256 digest  |
| `input`                       | Base64 bytes. The default is no bytes.        |
| `reason`                      | Text                                          |

A decimal integer has only the digits `0` to `9`. A negative integer starts
with `-`. It has no `+`, no spaces, and no decimal point. Base64 is the
standard alphabet with padding.

A receiver must reject an entry or a request that breaks these rules. A
receiver must also reject a required field that is missing.

The module URLs and `integrity` values in the examples are placeholders.
The URLs do not supply modules. Each digest has the correct format, but it
is not the digest of a module. Thus a client that reads these examples must
stop at the integrity check.

### `module`

```text
id: 0
event: module
data: time_ms=1&url=https%3A%2F%2Fexample.org%2Fgui%2Fcalculator.wasm&integrity=sha256-EXAMPLExCALCULATORxMODULExDIGESTxNOTxREALxA%3D&input=aGVsbG8%3D

```

`url` gives the location of the module. `integrity` gives the digest of the
module bytes. `input` gives the initial input of the module. The module URL
must always supply the same bytes.

A `module` entry after the first one replaces the module. The new module
does not get the state of the old module.

### `prefetch`

```text
id: 41
event: prefetch
data: url=https%3A%2F%2Fexample.org%2Fgui%2Fgraph.wasm&integrity=sha256-EXAMPLExGRAPHxCALCULATORxDIGESTxNOTxREALxxA%3D

```

A `prefetch` entry tells the client that a later `module` entry will
possibly use this module. The client can load and compile the module now.
The client can also ignore the entry. A `prefetch` entry does not change
shared state.

### `update`

```text
id: 42
event: update
data: time_ms=1830&update_id=f8d1c2
data: type=key&keysym=97&flags=1
data: type=pointer&mask=1&x=42&y=18

```

The first field line has `time_ms` and `update_id`. Each later field line is
one input. An `update` entry has one or more inputs. The order of the lines
is the order of the inputs.

| `type`    | Other fields       |
|-----------|--------------------|
| `key`     | `keysym`, `flags`  |
| `pointer` | `mask`, `x`, `y`   |

`keysym` is an X11 keysym. `flags`, `mask`, `x`, and `y` have the meanings
given in [Time and events](time-and-events.md). Coordinates are in the pixel
space of the first component, as in `qipgui`.

### `closed`

```text
id: 43
event: closed
data: reason=limit

```

`reason` is `limit` or `operator`. A client must accept other values and
show them to the user.

### Time

`time_ms` is a number of milliseconds on the channel clock. It is not
wall-clock time. Only the server sets `time_ms`. Only `module` and `update`
entries have `time_ms`.

The first `module` entry has a `time_ms` of `1` or more. Each later
`time_ms` is at least one more than the `time_ms` before it. This rule
applies even when two requests arrive in the same millisecond.

### Wakes

A component can ask for a wake. `finish_update()` returns a time. If that
time is after the `time_ms` of the update, it is the wake time of the
component. If it is equal, the component has no wake. A value before the
`time_ms` of the update is not valid. Then the client stops.

A wake is an update with no input at the wake time. The server does not log
wakes. Each client runs them. All clients run a wake at the same time and
with the same state, so all clients get the same result.

A wake is part of the shared history only if it is before the `time_ms` of
the next entry. Before a client applies an `update` entry, it runs each wake
that is before the `time_ms` of the entry. A wake at the same time as the
entry does not run. The entry runs in its place.

### The channel clock

```text
event: time
data: time_ms=2410

```

A `time` event gives the current time of the channel clock. It has no `id`
field and it does not change the `seq` of the last applied entry. Its
`time_ms` is never before the `time_ms` of an entry that the server sent
before it.

The server sends a `time` event after the stored entries of a stream. Then
it sends one at an interval, for example in place of a keepalive comment. It
does not send one before the stored entries, so a new client does not run
wakes before it has the history.

A client uses `time` events and the `time_ms` of entries to estimate the
channel clock. A good estimate is `time_ms - local_time` with the largest
value seen, plus the local time. This estimate is a little behind the server.

## Read the log

Open `GET /v1/channels/{capability}/events` with the header
`Accept: text/event-stream`. The server sends the stored entries in sequence
order. Then it keeps the response open and sends each new entry.

A request with no cursor starts at the most recent `module` entry. Entries
before that entry cannot change the state that the client shows. Thus the
first `seq` that a new client receives is not always `0`.

The server must select the replay range and register the live stream in one
atomic operation. This makes sure that no entry is lost between replay and
live delivery.

The response has an `Allow` header. A `HEAD` request to the same URL gets
the same headers without opening the stream. See
[Find the capability type](#find-the-capability-type).

The server can send SSE comments to keep the connection open. Comments and
`time` events are not log entries.

A client that reads the stream with `fetch()` must obey the SSE rules:

- An event ends at an empty line.
- The client discards an event that has no empty line after it.
- The client keeps the `data` lines of an event in their order.

Thus a client gets all of an `update` entry or none of it.

The SSE rules join the `data` lines of an event with LF characters. The
result is not one field line, so do not give it to `URLSearchParams` as one
value. Split the event data at each LF character. Then read each part as one
field line. A field line cannot contain LF, because the sender
percent-encodes each value. Thus the parts are the same as the `data` lines.

A client that uses `EventSource` gets the joined data in `event.data`. It
must split that value in the same way. A client that reads `fetch()` can
keep the `data` lines as a list and not join them.

An event that has an empty field line is not valid. An event that has no
`data` lines is also not valid.

The server uses the same rules to read the body of a POST.

### Reconnect

To reconnect, send the header `Last-Event-ID: N` or the query `?after=N`.
The server sends the entries with `seq` greater than `N`, then the live
entries. If the server removed some of those entries, it sends the entries
that it has. They start at the most recent `module` entry. A cursor that is
larger than the last `seq` is not valid. Use `?after=N` when the client reads the stream with `fetch()`.

A client obeys these rules:

- The first entry of a stream with no cursor must be a `module` entry. If it
  is not, stop.
- Apply a later entry only if its `seq` is one more than the last applied
  `seq`. A `module` entry is the one exception.
- Apply a `module` entry with a `seq` that is more than one after the last
  applied `seq`. This occurs when the server removed the entries before it.
  The entry discards the old state, so the missing entries are not
  necessary.
- Ignore an entry whose `seq` is already applied.
- Do not use a `time` event to find a gap. It has no `seq`.
- If there is a gap or the connection stops, close the stream. Then reconnect
  from the last applied `seq`.
- If an entry is not valid or has an unknown `event` value, stop. Tell the
  user that the client cannot continue.
- Do not apply an input because its POST response shows that the server
  accepted it. Apply it only when it arrives in the log.

## Apply an entry

### Apply a `module` entry

1. Load the module from `url`. A module from an earlier `prefetch` entry
   with the same `integrity` is permitted.
2. Calculate the SHA-256 digest of the module bytes.
3. Stop if the digest is not equal to the digest in `integrity`.
4. Discard the instance of the module before this one, if there is one.
5. Make a new instance. Decode `input` and give the bytes to the instance.
6. Call `render(input_size)` one time.
7. Call `begin_update_at(time_ms)`. Then call `finish_update()`.
8. Keep the wake time that `finish_update()` returns, if there is one.

Steps 7 and 8 are the bootstrap update. It has no input.

Keep the `module` entry and the `update` entries after it until the next
`module` entry. A replay needs them.

The module must export `begin_update_at` and `finish_update`. All clients
must use the same QIP component contract. A client can use local content
transforms to show the frame. Those transforms do not receive shared events.

### Apply an `update` entry

1. If the client ran an update at `time_ms` or later, replay. See
   [Run ahead and replay](#run-ahead-and-replay). Then stop this procedure.
2. Run each wake that is before `time_ms`, in time order.
3. Call `begin_update_at(time_ms)`.
4. For each input line, in order:
   - For `type=key`, call `key_event(keysym, flags)`.
   - For `type=pointer`, call `pointer_event(mask, x, y)`.
5. Call `finish_update()`. Keep the wake time that it returns.

The client can call `render(0)` after a completed update. The value that an
event function returns can prevent a render that is not necessary. It does
not change the log.

All clients apply the same logged update times and the same wakes. A client
must not use its local clock to set the time of an update. A client can use
its local clock to decide when to draw a frame.

Do not give local state to the component in an update. Local presentation
uniforms, such as size and focus, are set only before a render. They can
change the frame that a client shows, but not the component state. Thus the image bytes can be different on different terminals. Shared
update uniforms need a later protocol version.

### Run ahead and replay

A client can run wakes before the next entry arrives. Then an animation
plays when there is no input. Run each wake when the estimated channel clock
gets to its time.

An entry can then arrive with a `time_ms` that is not after the last update
that ran. The wakes at that time or later did not see the entry, so the state
is not correct. Replay:

1. Make a new instance of the module of the most recent `module` entry.
2. Apply the `module` entry again, from step 5.
3. Apply each kept `update` entry, and the new entry, in order. Run the
   wakes before each entry, as in steps 2 to 5 of the update procedure.
4. Draw one frame. Do not draw the frames between.
5. Continue to run wakes on the estimated channel clock.

The result is the same as on a client that did not run ahead. A replay
calls only update functions until step 4, so it costs less than drawing.
Because the clock estimate is a little behind the server, a replay occurs
only when an entry is slower than usual.

### Apply a `closed` entry

Do not call the module. Do not run more wakes. Keep the last frame. Tell the
user that the channel is closed. Do not reconnect.

A `closed` entry has no `time_ms`. Thus clients can show different frames
after it, if they ran different numbers of wakes.

## Send input

An editor sends one batch of input in each
`POST /v1/channels/{capability}/events`. The capability must be the write
capability. The header is `Content-Type: text/event-stream`. The body is
one SSE event in the same form as an `update` entry:

```text
event: update
data: update_id=f8d1c2
data: type=key&keysym=97&flags=1
data: type=pointer&mask=1&x=42&y=18

```

The first field line has a random `update_id`. The editor makes a new ID for
each batch and keeps it for retries. Each later field line is one input. A
batch has one or more inputs.

The body is different from the logged entry in only two items. It has no
`id` field, and its first field line has no `time_ms`. Only the server sets
these values.

The server reads the body with the same SSE rules as a client that reads the
log. These rules apply to the body:

- The body has one event, and the event ends with an empty line. Thus the
  server can find a body that is not complete.
- The `event` field is `update`.
- The body has no `id` field and no `time_ms` field.
- Each line ends with one LF character.

The server returns `400` for a body that breaks these rules.

A batch becomes one `update` entry. The server does not divide a batch and
does not join batches. To make the entry, the server adds the `id` field and
puts `time_ms` at the start of the first field line. It does not change the
other lines. Thus a client and a server can use one parser and one writer
for the two directions.

An editor sends one POST at a time. While it waits for the response, it
collects new input for the next batch. This keeps the inputs of one editor
in order.

The server does these steps for each POST:

1. Make sure that the capability permits writes and that the body is valid.
2. Assign `seq` and `time_ms`.
3. Store the entry durably.
4. Send the entry to all streams, which includes the stream of the sender.
5. Return `202`.

The server must not send an entry that it did not store.

The body of the `202` response is one field line:

```text
seq=42&time_ms=1830
```

### Retries

The server stores `update_id` with each accepted batch. Each ID is unique in
its channel. If a POST has a stored ID and the same body, the server returns
the initial `seq` and `time_ms`. It does not create a new entry. If a POST
has a stored ID and a different body, the server returns `409`.

After a timeout, the editor sends the POST again with the same ID and the
same body. It stops when it gets a response or when it sees that ID in the
log. A batch is confirmed only when its `update` entry arrives in the log.

The ID lets an editor find its own confirmed batch in the log. It does not
change the order of the log.

### Status codes

| Status | Meaning                                                        |
|--------|----------------------------------------------------------------|
| `202`  | The server stored the batch.                                   |
| `400`  | The cursor or the batch is not valid.                          |
| `403`  | The capability is a read capability. `Allow` is `GET`.         |
| `404`  | The capability is unknown, or the server deleted the channel.  |
| `409`  | The `update_id` is in use with a different body.               |
| `410`  | The channel is closed. The server accepts no more input.       |
| `429`  | The input rate is too high. Send the batch again later.        |
| `503`  | The server could not store the batch. Send it again.           |

`410` applies only to POST requests. A closed channel stays readable until
the server deletes it.

The `202`, `403`, and `410` responses have an `Allow` header. See
[Find the capability type](#find-the-capability-type).

After `429`, `503`, or a timeout, the client keeps the batch as pending and
tries again. After `410`, the client reads the log to the `closed` entry.
A pending batch that is not in the log before that entry is lost. The
client discards it and tells the user.

## Change the module

Only the server appends `module` and `prefetch` entries. This protocol does
not specify what causes the server to append them.

To change the module, the server appends a `module` entry. The entry gets
its `seq` and `time_ms` by the same rules as an `update` entry. Each client
applies it in sequence order. Input that the server stores after the entry
goes to the new module.

The server can append a `prefetch` entry before the `module` entry. This
gives each client time to load the module before the change.

## Close a channel

The server closes a channel when it reaches a limit or when the operator
closes it. To close a channel, the server appends one `closed` entry. The
`closed` entry is always the last entry in the log.

After the `closed` entry, these rules apply:

- The server ends each stream after it sends the entry.
- The server returns `410` for each POST to the channel.
- The server continues to serve the stored log to read requests. A replay
  ends with the `closed` entry, and then the server ends the stream.

The server keeps a closed channel for a retention time that the server sets.
Then it deletes the channel. After that, all requests with its capabilities
return `404`. The only way to revoke a capability is to close the channel,
which stops writes, and then to delete it, which stops reads.

## Failures and limits

A new client replays the log from the most recent `module` entry before it
shows live state. The client stops and tells the user that it cannot join
the channel in these conditions:

- It cannot load the module.
- The replay fails.
- The server does not have all entries from the most recent `module` entry.

The client must not start from a later sequence without those entries. The
server must keep them while the channel is not deleted. The server can
remove entries that are before the most recent `module` entry.

The server can end a slow SSE connection. The client then reconnects from
its last applied `seq`.

The server must set limits for these values:

- Module input size
- Batch body size
- Number of inputs in one batch
- Input rate
- Channel lifetime
- Stored log size

The server returns `400` for a batch that is too large and `429` for a rate
that is too high. When a channel reaches its lifetime or log size limit, the
server closes it.

This protocol does not supply late-join snapshots, server-side state checks,
or audio.
