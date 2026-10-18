//// Minimal hackney client layer, vendored from httpp 1.8.0
//// (https://github.com/VioletBuse/httpp, Apache-2.0, Copyright VioletBuse)
//// when nexus migrated to gleam_stdlib 1.x: httpp's latest release pins
//// `gleam_stdlib ~> 0.65` and has been unmaintained since Nov 2025.
////
//// Only the surface nexus consumes is kept:
////
//// - `send` — buffered (non-streaming) requests, used by the
////   `list_models` preflight and the zero-events buffered retry;
//// - the async-response types plus `close` and `selecting_http_message`,
////   which type hackney's stream messages for the selector receive in
////   `nexus/openai`.
////
//// Streaming request setup itself goes through
//// `nexus_boot_ffi.hackney_stream_start`, which exists so the request can
//// set hackney's `recv_timeout` (the `send` here hard-wires hackney's
//// five-second default).

import gleam/bit_array
import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic/decode.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process.{type Selector}
import gleam/http.{type Method}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/result
import gleam/string
import gleam/uri

pub type Error {
  Other(Dynamic)
  ConnectionClosed(partial_body: BitArray)
  TimedOut
  /// The response body was not valid UTF-8.
  InvalidUtf8Response
}

/// A hackney client ref.
pub type ClientRef

pub type HackneyResponse {
  /// Received when neither `WithBody` nor `Async` is used.
  ClientRefResponse(
    status: Int,
    headers: List(#(String, String)),
    client_ref: ClientRef,
  )
  /// Received with the `WithBody(True)` option.
  BinaryResponse(status: Int, headers: List(#(String, String)), body: BitArray)
  /// Received on a HEAD request when the response succeeded.
  EmptyResponse(status: Int, headers: List(#(String, String)))
  /// Received with the `Async` option; the client ref disambiguates the
  /// stream messages delivered to the owning process.
  AsyncResponse(client_ref: ClientRef)
}

pub type Options {
  WithBody(Bool)
  /// Disable the hackney connection pool.
  Pool(Bool)
}

@external(erlang, "nexus_hackney_ffi", "send")
fn send_ffi(
  method: Method,
  url: String,
  headers: List(#(String, String)),
  body: BytesTree,
  options: List(Options),
) -> Result(HackneyResponse, Error)

@external(erlang, "nexus_hackney_ffi", "close")
pub fn close(ref: ClientRef) -> Nil

/// Fetch the full body for a client-ref response. Note hackney returns raw
/// error terms here (not tagged like `Error`), so only inspect the error.
@external(erlang, "hackney", "body")
fn body_ffi(ref: ClientRef) -> Result(BitArray, Error)

/// A decoded hackney stream message, as delivered to the process that
/// started an async request.
pub type HackneyMessage {
  Status(Int)
  Headers(List(#(String, String)))
  Binary(BitArray)
  Redirect(String, List(#(String, String)))
  SeeOther(String, List(#(String, String)))
  DoneStreaming
  /// The message could not be decoded; the raw term is retained.
  NotDecoded(Dynamic)
}

@external(erlang, "nexus_hackney_ffi", "insert_selector_handler")
fn insert_selector_handler(
  selector: Selector(payload),
  for for: tag,
  mapping mapping: fn(message) -> payload,
) -> Selector(payload)

/// Select hackney stream messages related to an async request, mapping them
/// to `HackneyMessage`.
pub fn selecting_http_message(
  selector: Selector(a),
  mapping transform: fn(ClientRef, HackneyMessage) -> a,
) -> Selector(a) {
  let handler = fn(message: #(atom.Atom, ClientRef, Dynamic)) {
    let header_list_decoder =
      decode.list({
        use name <- decode.field(0, decode.string)
        use value <- decode.field(1, decode.string)
        decode.success(#(name, value))
      })

    let status_decoder = {
      use code <- decode.field(1, decode.int)
      decode.success(Status(code))
    }

    let headers_decoder = {
      use headers <- decode.field(1, header_list_decoder)
      decode.success(Headers(headers))
    }

    let redirect_decoder = {
      use location <- decode.field(1, decode.string)
      use headers <- decode.field(2, header_list_decoder)
      decode.success(Redirect(location, headers))
    }

    let see_other_decoder = {
      use data <- decode.field(1, decode.string)
      use headers <- decode.field(2, header_list_decoder)
      decode.success(SeeOther(data, headers))
    }

    let discriminant_decoder = {
      use discriminant <- decode.field(0, atom.decoder())

      case atom.to_string(discriminant) {
        "status" -> status_decoder
        "headers" -> headers_decoder
        "redirect" -> redirect_decoder
        "see_other" -> see_other_decoder
        _ -> decode.failure(DoneStreaming, "HackneyMessage")
      }
    }

    let binary_decoder = {
      use binary <- decode.then(decode.bit_array)
      decode.success(Binary(binary))
    }

    let done_decoder = {
      use atom <- decode.then(atom.decoder())
      case atom.to_string(atom) {
        "done" -> decode.success(DoneStreaming)
        _ -> decode.failure(DoneStreaming, "HackneyMessage")
      }
    }

    let error_decoder = {
      use dynamic <- decode.then(decode.dynamic)
      decode.success(NotDecoded(dynamic))
    }

    let decoder =
      decode.one_of(binary_decoder, or: [
        discriminant_decoder,
        done_decoder,
        error_decoder,
      ])

    let assert Ok(http_message) = decode.run(message.2, decoder)

    transform(message.1, http_message)
  }

  let tag = atom.create("hackney_response")

  insert_selector_handler(selector, #(tag, 3), handler)
}

/// Send a buffered request and read the whole response body as a string.
pub fn send(req: Request(String)) -> Result(Response(String), Error) {
  use response <- result.try(
    req
    |> request.map(bytes_tree.from_string)
    |> send_bits,
  )

  case bit_array.to_string(response.body) {
    Ok(body) -> Ok(response.set_body(response, body))
    Error(_) -> Error(InvalidUtf8Response)
  }
}

fn send_bits(req: Request(BytesTree)) -> Result(Response(BitArray), Error) {
  let options = [WithBody(False), Pool(False)]

  use response <- result.try(
    req
    |> request.to_uri
    |> uri.to_string
    |> send_ffi(req.method, _, req.headers, req.body, options),
  )

  let result = case response {
    ClientRefResponse(status, headers, client_ref) ->
      body_ffi(client_ref)
      |> result.map(fn(body_bits) {
        #(status, process_headers(headers), body_bits)
      })
    BinaryResponse(status, headers, binary) ->
      Ok(#(status, process_headers(headers), binary))
    EmptyResponse(status, headers) ->
      Ok(#(status, process_headers(headers), <<>>))
    AsyncResponse(_client_ref) ->
      // Unreachable: `send` never passes the `Async` option.
      panic as "received async response from buffered hackney send"
  }

  use #(status, headers, binary) <- result.try(result)

  Ok(response.Response(status, headers, binary))
}

fn process_headers(
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  list.map(headers, fn(header) { #(string.lowercase(header.0), header.1) })
}
