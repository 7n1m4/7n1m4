// SPDX-License-Identifier: GPL-3.0-or-later

//! A renderer handler that never returns must not block the connection
//! reader: heartbeats on the same socket still get answered, and the hung
//! RPC gets a typed deadline error once the server-side deadline expires.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anima_channel::ws::MAX_WS_PAYLOAD_BYTES;
use anima_channel::{
    accept_key, encode_frame, ChannelConfig, ChannelServer, Frame, FrameDecoder, RendererHandlers,
    OP_TEXT,
};

const CLIENT_KEY: &str = "dGhlIHNhbXBsZSBub25jZQ==";
const TOKEN: &str = "deadline-test-token";

fn tcp_connect(port: u16) -> TcpStream {
    let stream = TcpStream::connect(("127.0.0.1", port)).expect("connect");
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    stream
}

fn http_upgrade(stream: &mut TcpStream, port: u16) {
    let request = format!(
        "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {CLIENT_KEY}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    );
    stream.write_all(request.as_bytes()).unwrap();
    let mut response = Vec::new();
    let mut chunk = [0u8; 1024];
    loop {
        let n = stream.read(&mut chunk).unwrap();
        assert!(n > 0, "server closed during upgrade");
        response.extend_from_slice(&chunk[..n]);
        if response.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
    }
    assert!(String::from_utf8(response)
        .unwrap()
        .starts_with("HTTP/1.1 101"));
}

fn send_text(stream: &mut TcpStream, text: &str) {
    stream
        .write_all(&encode_frame(OP_TEXT, text.as_bytes(), Some([1, 2, 3, 4])))
        .unwrap();
}

fn read_frame(stream: &mut TcpStream, decoder: &mut FrameDecoder) -> Frame {
    let mut chunk = [0u8; 4096];
    loop {
        if let Some(frame) = decoder.next_frame().unwrap() {
            return frame;
        }
        let n = stream.read(&mut chunk).expect("read frame");
        assert!(n > 0, "server closed connection");
        decoder.push(&chunk[..n]);
    }
}

#[test]
fn hung_handler_does_not_block_reader() {
    let config = ChannelConfig {
        hostname: "127.0.0.1".to_string(),
        auth_token: TOKEN.to_string(),
        tls_config: None,
        allow_actions: None,
    };
    let entered = Arc::new(AtomicBool::new(false));
    let entered_in_handler = Arc::clone(&entered);
    let mut handlers = RendererHandlers::new();
    handlers.insert(
        "hang".to_string(),
        Box::new(move |_method, _payload| {
            entered_in_handler.store(true, Ordering::SeqCst);
            std::thread::sleep(Duration::from_secs(60));
            Ok(serde_json::json!({}))
        }),
    );
    let server = ChannelServer::bind_with_renderer("127.0.0.1", 0, &config, handlers)
        .unwrap()
        .with_handler_deadline(Duration::from_millis(400));
    let handle = server.spawn().unwrap();
    let port = handle.port();
    let mut stream = tcp_connect(port);
    let mut decoder = FrameDecoder::new(MAX_WS_PAYLOAD_BYTES);
    http_upgrade(&mut stream, port);
    send_text(
        &mut stream,
        &format!(r#"{{"type":"auth","authToken":"{TOKEN}"}}"#),
    );
    let auth = read_frame(&mut stream, &mut decoder);
    assert!(String::from_utf8(auth.payload)
        .unwrap()
        .contains(r#""ok":true"#));

    send_text(
        &mut stream,
        r#"{"type":"rpc","action":"renderer.hang","payload":{},"id":"hang-1"}"#,
    );
    // The handler must actually be running before the progress check.
    let mut waited = Duration::ZERO;
    while !entered.load(Ordering::SeqCst) && waited < Duration::from_secs(2) {
        std::thread::sleep(Duration::from_millis(10));
        waited += Duration::from_millis(10);
    }
    assert!(entered.load(Ordering::SeqCst), "hung handler never started");

    // The pending RPC fails with a typed deadline error instead of hanging
    // the reader until the dead-peer TTL expires.
    let reply = read_frame(&mut stream, &mut decoder);
    let rpc: serde_json::Value = serde_json::from_slice(&reply.payload).unwrap();
    assert_eq!(rpc["action"], "renderer.hang");
    assert_eq!(rpc["ok"], false);
    assert_eq!(rpc["id"], "hang-1");
    assert_eq!(rpc["error"]["code"], "rpc_handler_timeout");

    // Reader is still alive after the deadline: heartbeats are answered.
    send_text(
        &mut stream,
        r#"{"type":"transport:connection:heartbeat","data":{"kind":"ping"}}"#,
    );
    let pong = read_frame(&mut stream, &mut decoder);
    let pong_json: serde_json::Value = serde_json::from_slice(&pong.payload).unwrap();
    assert_eq!(pong_json["type"], "transport:connection:heartbeat");
    assert_eq!(pong_json["data"]["kind"], "pong");

    send_text(&mut stream, r#"{"type":"ping"}"#);
    let pong = read_frame(&mut stream, &mut decoder);
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&pong.payload).unwrap()["type"],
        "pong"
    );
    handle.stop();
}
