---
name: lustre-web-development
description: Gleam Lustre web development patterns, event handlers, and server components
license: MIT
compatibility:
  lustre: ">= 5.0.0"
---

# Lustre Web Development

A guide for building web applications with Gleam's Lustre framework, focusing on server components, WebSocket integration, and event handling patterns.

## Server Component Pattern

### Basic Setup

Server components use Lustre with WebSocket connections for real-time updates. The pattern consists of three files:

1. **Component file** (e.g., `src/agent/chat.gleam`): The Lustre application
2. **Socket file** (e.g., `src/agent/socket.gleam`): WebSocket handler
3. **Router integration**: Add routes to both HTTP and WebSocket handlers

### Component Structure

```gleam
import gleam/erlang/process
import lustre.{type App}
import lustre/attribute as at
import lustre/element/html as ht
import lustre/element.{type Element}
import lustre/effect
import lustre/event
import lustre/server_component

pub fn component() -> App(process.Name(ExternalMsg), Model, Msg) {
  lustre.application(init, update, view)
}

pub type Model {
  Model(
    // Your model fields
  )
}

fn init(name: process.Name(ExternalMsg)) -> #(Model, effect.Effect(Msg)) {
  let model = Model()
  #(model, subscribe(name, ExternalMsg))
}

pub type ExternalMsg {
  // Messages from other actors
  YourExternalMsg
}

pub opaque type Msg {
  ExternalMsg(ExternalMsg)
  // Your internal messages
  UserClickedButton
  UserTypedInput(String)
}

fn subscribe(
  name: process.Name(ext),
  on_msg: fn(ext) -> msg,
) -> effect.Effect(msg) {
  use _, _ <- server_component.select

  let assert Ok(_) = process.register(process.self(), name)
  let subj = process.named_subject(name)

  process.new_selector()
  |> process.select_map(subj, on_msg)
}
```

## Event Handlers

### Text Input

Controlled inputs work for plain fields — but read
[Inputs: Controlled vs Uncontrolled](#inputs-controlled-vs-uncontrolled-server-components)
first: with server components, controlled drafts can race queued `input`
echoes over the WebSocket.

```gleam
pub opaque type Msg {
  UserTypedInput(String)
}

// In view function:
ht.input([
  at.class("chat-input"),
  at.placeholder("Type here..."),
  at.value(model.input),
  event.on_input(UserTypedInput),
  at.type_("text"),
])
```

### Button Click

```gleam
pub opaque type Msg {
  UserClickedButton
}

// In view function:
ht.button([event.on_click(UserClickedButton)], [
  ht.text("Click me")
])
```

### Form Submission

`event.on_submit` **works** with server components (Lustre ≥ 5). It
decodes `detail.formData` (a list of `#(name, value)` pairs the client
runtime assembles from the live form) and automatically `preventDefault`s
the browser's native submission. State which fields the decoder needs via
`server_component.include`:

```gleam
pub opaque type Msg {
  UserSubmittedForm(String)
}

// In view function — the form owns the submit handler:
ht.form(
  [event.on_submit(fn(entries) {
    case list.find(entries, fn(e) { e.0 == "text" }) {
      Ok(#(_, value)) -> UserSubmittedForm(value)
      Error(_) -> Ignored
    }
  })
  |> server_component.include(["detail.formData"])],
  [
    ht.textarea([at.name("text")], ""),
    ht.button([at.type_("submit")], [ht.text("Send")]),
  ],
)
```

Notes:

- The submit button needs `at.type_("submit")`; any other button inside the
  form must explicitly be `at.type_("button")` or it will submit too.
- Enter in a `<textarea>` does **not** trigger form submission (only
  single-line inputs do) — see [Enter-to-send](#enter-to-send-textarea) below.
- `at.action("#")` documents that no navigation is intended.

### Custom Events with Data

For events that need to pass data:
```gleam
pub opaque type Msg {
  UserSelectedOption(String)
}

// In view function:
ht.select([
  event.on_change(UserSelectedOption),
  at.value(model.selected_option),
], [
  ht.option([at.value("option1")], [ht.text("Option 1")]),
  ht.option([at.value("option2")], [ht.text("Option 2")]),
])
```

## Inputs: Controlled vs Uncontrolled (Server Components)

Three transport facts drive every input decision in a server component:

1. **No conditional `preventDefault`.** The handler runs on the server,
   long after the browser already ran the default action. Lustre's
   `event.prevent_default` is unconditional per event name — applying it to
   `keydown` blocks *all* typing (docs say so explicitly for
   [`event.advanced`](https://hexdocs.pm/lustre/lustre/event.html)).
2. **One WS message in flight.** The client queues events and flushes the
   queue only when the next server message arrives. A controlled draft races
   against the queued `input` echo: a default action you didn't want (e.g.
   Enter's newline) mutates the DOM, fires `input`, and that echo lands
   *after* your next render — re-polluting the model with stale text.
3. **Value sync is attribute-based.** Lustre's runtime syncs `value` via a
   special-cased attribute (`node.value = ...`). Rendering a `<textarea>`'s
   content as children patches text nodes, which **never** update a
   textarea's `value` property after mount. Use `at.value(...)` if you need
   patches to reach the field at all.

For a chat composer (Enter-to-send), the race in (1)+(2) is unwinnable with a
controlled draft. Use the pattern Lustre documents in
[controlled-vs-uncontrolled-inputs](https://github.com/lustre-labs/lustre/blob/main/pages/hints/controlled-vs-uncontrolled-inputs.md):
**uncontrolled input inside a keyed container**:

- No `on_input` at all — the field owns its text; zero per-keystroke traffic.
- Read the text from the event itself: `target.value` at `keydown` time is
  read *before* the default action runs, so it is exactly what the user sees.
- Clear the field by **rotating the key**: a changed key makes the diff
  replace the element wholesale. Recreate it with `at.autofocus(True)` —
  autofocus is a runtime-synced attribute, so the fresh element grabs focus.

### Enter-to-send textarea

```gleam
import lustre/element/keyed

// Model: composer: Int  — bumped on accepted send (SendAccepted)

fn composer(model: Model) -> Element(Msg) {
  keyed.element("form", [at.id("composer"), submit_requested()], [
    #(
      "composer-" <> int.to_string(model.composer),  // rotation key
      ht.textarea(
        [
          at.name("text"),
          at.autofocus(True),
          enter_key(),
        ],
        "",  // uncontrolled: content stays ""
      ),
    ),
    #("controls", ht.div([at.class("buttons")], [send_button()])),
  ])
}

fn enter_key() -> attr.Attribute(Msg) {
  let decoder = {
    use key <- decode.field("key", decode.string)
    // Value read BEFORE the newline default runs — newline-free by design.
    use value <- decode.subfield(["target", "value"], decode.string)
    use shift <- decode.optional_field("shiftKey", False, decode.bool)
    use composing <- decode.optional_field("isComposing", False, decode.bool)
    case key, shift, composing {
      // Plain Enter sends; Shift+Enter keeps the browser newline (multi-line);
      // isComposing guards IME confirmation Enters.
      "Enter", False, False -> SendRequested(value)
      _, _, _ -> Ignored
    }
    |> decode.success
  }
  event.on("keydown", decoder)
  |> server_component.include(["key", "target.value", "shiftKey", "isComposing"])
}

// SendAccepted -> Model(..model, composer: model.composer + 1, streaming: True)
```

Known trade-off: for one round-trip between Enter and the accept event the
newline may flash briefly before the keyed replacement wipes it. The only
alternative is client-side JS in the page (preventDefault in a capture
listener) — which a zero-client-JS page rules out, and which **cannot reach
into a closed shadow root** anyway (see Shadow DOM section).

### When controlled *is* fine

Use `at.value(model.field)` + `event.on_input` for short fields (search
boxes, pickers) where no default action fights you. Consider
`event.debounce(handler, 200)` to cut per-keystroke round trips. For long
text or send-on-Enter flows, prefer the uncontrolled pattern above.

## WebSocket Integration

### Socket Handler Pattern

```gleam
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http/request.{type Request}
import gleam/json
import gleam/option.{type Option, Some}
import lustre
import lustre/server_component
import mist.{type Connection}
import web

pub fn html() {
  server_component.element([server_component.route("/ws/chat")], [])
  |> web.layout(title: "Chat Page")
  |> Ok
  |> web.html_response
}

pub fn serve(request: Request(Connection), component) {
  mist.websocket(
    request:,
    on_init: init_socket(_, component),
    handler: loop_socket,
    on_close: close_socket,
  )
}

type Socket {
  Socket(
    component: lustre.Runtime(your_component.Msg),
    self: Subject(server_component.ClientMessage(your_component.Msg)),
  )
}

type SocketMessage =
  server_component.ClientMessage(your_component.Msg)

fn init_socket(_, component) -> #(Socket, Option(Selector(SocketMessage))) {
  let self = process.new_subject()
  let selector =
    process.new_selector()
    |> process.select(self)

  server_component.register_subject(self)
  |> lustre.send(to: component)

  #(Socket(component:, self:), Some(selector))
}

fn loop_socket(
  state: Socket,
  message: mist.WebsocketMessage(SocketMessage),
  connection: mist.WebsocketConnection,
) -> mist.Next(Socket, SocketMessage) {
  case message {
    // Client → Server messages (input, clicks)
    mist.Text(json) -> {
      case json.parse(json, server_component.runtime_message_decoder()) {
        Ok(runtime_message) -> lustre.send(state.component, runtime_message)
        Error(_) -> Nil
      }
      mist.continue(state)
    }

    mist.Binary(_) -> mist.continue(state)

    // Server → Client messages (UI updates)
    mist.Custom(client_message) -> {
      let json = server_component.client_message_to_json(client_message)
      let assert Ok(_) = mist.send_text_frame(connection, json.to_string(json))
      mist.continue(state)
    }

    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

fn close_socket(state: Socket) -> Nil {
  server_component.deregister_subject(state.self)
  |> lustre.send(to: state.component)
}
```

## Router Integration

### Add to Context

```gleam
// In src/web.gleam
import your_component

pub type Context {
  Context(
    db: process.Name(pog.Message),
    your_component: lustre.Runtime(your_component.Msg),
  )
}
```

### Add HTTP Route

```gleam
// In src/router.gleam - wisp_handler
case wisp.path_segments(req) {
  // ... existing routes ...
  ["chat"] -> your_socket.html()
  _ -> wisp.not_found()
}
```

### Add WebSocket Route

```gleam
// In src/router.gleam - mist_handler
case request.path_segments(req) {
  // ... existing routes ...
  ["ws", "chat"] -> your_socket.serve(req, ctx.your_component)
  _ -> next(req)
}
```

### Update Supervisor

```gleam
// In src/nexus.gleam
import your_component

let your_component = process.new_name("your_component")

use your_component_runtime <- try(
  lustre.start_server_component(your_component.component(), your_component)
  |> what_failed("your component"),
)

// Pass to mist_starter
supervisor.add(mist_starter(db_pool, automation_viewer_component, your_component_runtime))

// Update mist_starter signature and Context
```

## Common Patterns

### Model Update with List

```gleam
fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    AddItem(item) -> {
      let new_items = [item, ..model.items]
      #(Model(..model, items: new_items), effect.none())
    }
  }
}
```

### Prevent Redundant Updates

```gleam
fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    UpdateInput(text) -> {
      case text == model.input {
        True -> #(model, effect.none())  // Skip if unchanged
        False -> #(Model(..model, input: text), effect.none())
      }
    }
  }
}
```

### External Message Handling

```gleam
fn update(model: Model, msg: Msg) -> #(Model, effect.Effect(Msg)) {
  case msg {
    ExternalMsg(ext) -> {
      case ext {
        AddMessage(msg) -> {
          let new_messages = [msg, ..model.messages]
          #(Model(..model, messages: new_messages), effect.none())
        }
      }
    }
    UserClickedSend -> {
      // Handle user action
      #(model, effect.none())
    }
  }
}
```

## Common Pitfalls

### 1. Conditional preventDefault in Server Components

**Error**: wanting to cancel only *some* events' default action (e.g. Enter
in a textarea) — the handler runs server-side, after the default already
happened; a blanket `event.prevent_default` on `keydown` blocks all typing.

**Fix**: restructure so the default is harmless — uncontrolled inputs,
reading `target.value` at keydown time, keyed replacement to clear (see
[Inputs: Controlled vs Uncontrolled](#inputs-controlled-vs-uncontrolled-server-components)).

### 2. `html.textarea` Takes a String, Not Children

**Error**: `ht.textarea([attrs], [ht.text(model.draft)])` — type error.

**Fix**: `ht.textarea([attrs], model.draft)` — the second argument is the
content `String` (which also sets a `value` property on the element).

### 3. `decode.at` Is Not `use`-able

**Error**: `use value <- decode.at(["target", "value"], decode.string)` —
arity error (all args already supplied).

**Fix**: `use value <- decode.subfield(["target", "value"], decode.string)`.

### 4. External Messages Not Received

**Error**: Component not getting messages from actors

**Fix**: Ensure `subscribe` effect is in `init` and `process.register()` succeeds

### 5. Duplicate Route Definitions

**Error**: Multiple routes causing 404s

**Fix**: Check both HTTP and WebSocket route handlers in router.gleam

### 6. Context Type Mismatch

**Error**: Type errors when accessing component in Context

**Fix**: Update `web.Context` type and `mist_starter` function signature to include new component

### 7. Attribute Module Confusion

**Error**: Using wrong attribute functions

**Fix**: Import `lustre/attribute as at` and use `at.class()`, `at.value()`, etc.

## CSS Integration

Add CSS file to `priv/static/your-style.css` and include in layout:

```gleam
// In src/web.gleam - layout function
ht.link([at.rel("stylesheet"), at.href("/static/your-style.css")]),
```

### CSS Inheritance in Shadow DOM

Server components always render into a shadow root. In Lustre ≥ 5,
`component.adopt_styles` defaults to `True`: the runtime copies/adopts the
page's stylesheets into the shadow root on mount, so page CSS styles the
component out of the box. Set `component.adopt_styles(False)` only if you
ship component-scoped styles instead.

`component.open_shadow_root` defaults to `True` (an *open* root — page JS
can reach inside via `host.shadowRoot` or `event.composedPath()`). Passing
`False` gives a **closed** root — not light DOM — and closed means page JS
cannot see inside even via `composedPath()`: event targets retarget to the
host element. Useful for encapsulation, fatal for page-script helpers.

## Shadow DOM JavaScript

### Accessing Elements Inside Shadow DOM

`document.querySelector()` cannot find elements inside a server component's shadow DOM. From an element inside the component, use `getRootNode()` to access the shadow root:

```gleam
// Inline onclick to scroll a container inside the server component
ht.button(
  [
    at.attribute(
      "onclick",
      "const sr=this.getRootNode();const el=sr.querySelector('.scrollable');if(el){el.scrollTop=el.scrollHeight}",
    ),
  ],
  [ht.text("Scroll to bottom")],
)
```

**Key pattern**: `this.getRootNode()` returns the shadow root when called from an element inside it. Use this to query other elements within the same server component.

### Limitations

- `before_paint` and `after_paint` effects are ignored for server components
- External JavaScript cannot directly access shadow DOM elements without a reference
- `autofocus` **is** honoured via runtime sync (it re-`focus()`es when the
  attribute is applied to a freshly created element) — handy after keyed
  replacements to restore focus without JS

## Testing

### Protocol-Level Testing (No Browser)

The server-component flow is testable end-to-end with a plain WebSocket
client speaking the runtime protocol — valuable for the class of bug that
only shows up over the transport (echo races, patch shapes, event routing).

Wire format (client → server): one JSON object per frame,
`{"kind":3,"messages":[{"kind":1,"path":"…","name":"keydown","event":{…}}]}`
(`kind:1` = event_fired, `kind:0` = attribute_changed, `kind:2` =
property_changed, wrapped in `kind:3` batches). Server → client: `kind:0`
mount (full vdom), `kind:1` reconcile (patch tree).

Event **path** rules (must match exactly or the server silently drops the
event):

- Segments joined with `"\t"`; the view root element contributes a leading
  `"0"` (its index inside the mount container).
- Plain children contribute their **index**; **keyed children contribute
  their key string** (e.g. `"0\t1\t1\t1\tcomposer-0"`).
- The handler cache keys on `path <> "\n" <> event_name`.

Auto-included event fields (no `server_component.include` needed): `key` for
keydown/keyup/keypress, `target.value`/`target.checked` for input/change,
`detail.formData` for submit. Everything else your decoder reads must be
listed in `include`.

With this, a ~150-line raw-socket script verified: mount vdom shape, event
decoding, and that a key rotation produces a keyed **Replace** patch (the
clearing mechanism) — before any browser was involved.

### Manual Testing Checklist

1. ✅ HTTP route loads HTML page
2. ✅ WebSocket route connects successfully
3. ✅ Browser console shows no WebSocket errors
4. ✅ Clicks and input send messages to server
5. ✅ External messages update UI in real-time
6. ✅ Page refresh reconnects WebSocket
7. ✅ Multiple browser tabs work independently
8. ✅ Composer: Enter sends and the field clears + refocuses; Shift+Enter
   inserts a newline (and only sends on the next plain Enter)

## Reference

- [Lustre Documentation](https://lustre.build/)
- [Lustre Examples](https://github.com/lustre-labs/lustre/tree/main/examples)
- [Mist WebSocket](https://hexdocs.pm/mist/)
- [Gleam Process](https://tour.gleam.run/basics/processes/)
