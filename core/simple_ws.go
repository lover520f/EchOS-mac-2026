//go:build !windows

package main

import (
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// 「简易 WebSocket 代理」协议。
//
// 社区里流传的 Cloudflare Worker 服务端（就是 `WebSocket Proxy Server` 那一版）
// 用的并不是 x-tunnel 的 smux 多路复用协议，而是一套朴素得多的东西：
//
//	客户端 → 服务端   文本  "CONNECT:example.com:443|"   建立到目标的连接
//	服务端 → 客户端   文本  "CONNECTED"                   连上了
//	双向              二进制 原始字节                      之后就是纯透传
//	任意方向          文本  "CLOSE" / "ERROR:xxx"         结束
//
// 关键差别是**一个 WebSocket 只服务一条 TCP 连接**，没有多路复用。
// 客户端如果按 smux 那套发帧，服务端因为没收到过 CONNECT，remoteWriter 是 null，
// 会把所有二进制帧默默丢掉 —— 表现就是"握手成功、认证通过、然后永远没有响应"。
//
// 这里实现这套协议，让 EchOS 能直连这类服务端。

const (
	simpleConnectTimeout = 8 * time.Second
)

// simpleWSConn 把一条「已 CONNECTED 的 WebSocket」包装成 net.Conn。
type simpleWSConn struct {
	ws     *websocket.Conn
	reader io.Reader

	readMu  sync.Mutex
	writeMu sync.Mutex

	closed   atomic.Bool
	closeErr error

	// readData 标记这条隧道是否收到过服务端返回的任何真实数据。
	// wroteAt 记录客户端第一次发数据的时刻。
	// 黑洞检测依据：客户端已经发过数据（wroteAt != 0）、服务端却一直没回
	// （readData 仍 false），超过时限即判定服务端"假成功"黑洞（如 Worker
	// 兼容日期不对）—— 握手通了但出站数据根本不转发。只看"双方任一向有数据"
	// 不够：客户端自己会发数据（Write），那样黑洞就漏判了。
	readData atomic.Bool
	wroteAt  atomic.Int64
}

func (c *simpleWSConn) Read(p []byte) (int, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()
	for {
		if c.reader == nil {
			mt, r, err := c.ws.NextReader()
			if err != nil {
				return 0, err
			}
			if mt == websocket.TextMessage {
				// 控制消息：CLOSE 表示对端结束，ERROR: 带出服务端的失败原因
				msg, _ := io.ReadAll(r)
				text := string(msg)
				switch {
				case text == "CLOSE":
					return 0, io.EOF
				case strings.HasPrefix(text, "ERROR:"):
					return 0, fmt.Errorf("服务端错误: %s", strings.TrimPrefix(text, "ERROR:"))
				default:
					// CONNECTED 之类的多余控制字，忽略继续读
					continue
				}
			}
			if mt != websocket.BinaryMessage {
				continue
			}
			c.reader = r
		}
		n, err := c.reader.Read(p)
		if errors.Is(err, io.EOF) {
			c.reader = nil
			if n > 0 {
				c.readData.Store(true)
				return n, nil
			}
			continue
		}
		if n > 0 {
			c.readData.Store(true)
		}
		return n, err
	}
}

func (c *simpleWSConn) Write(p []byte) (int, error) {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	// 一律走二进制帧：服务端那边 `data instanceof ArrayBuffer` 分支直接透传，
	// 不能用文本 DATA: 前缀 —— 那条路径会经过 TextEncoder，二进制数据会被 UTF-8 改写。
	if err := c.ws.WriteMessage(websocket.BinaryMessage, p); err != nil {
		return 0, err
	}
	if c.wroteAt.Load() == 0 {
		c.wroteAt.Store(time.Now().UnixNano())
	}
	return len(p), nil
}

func (c *simpleWSConn) Close() error {
	if !c.closed.CompareAndSwap(false, true) {
		return c.closeErr
	}
	c.writeMu.Lock()
	_ = c.ws.WriteMessage(websocket.TextMessage, []byte("CLOSE"))
	c.writeMu.Unlock()
	c.closeErr = c.ws.Close()
	return c.closeErr
}

func (c *simpleWSConn) LocalAddr() net.Addr  { return c.ws.LocalAddr() }
func (c *simpleWSConn) RemoteAddr() net.Addr { return c.ws.RemoteAddr() }

func (c *simpleWSConn) SetDeadline(t time.Time) error {
	_ = c.ws.SetReadDeadline(t)
	return c.ws.SetWriteDeadline(t)
}
func (c *simpleWSConn) SetReadDeadline(t time.Time) error  { return c.ws.SetReadDeadline(t) }
func (c *simpleWSConn) SetWriteDeadline(t time.Time) error { return c.ws.SetWriteDeadline(t) }

// pickIP 从优选 IP 列表里轮流取一个，没配就返回空串（直接解析服务器域名）。
var simpleIPCounter uint64

func (p *ECHPool) pickIP() string {
	if len(p.targetIPs) == 0 {
		return ""
	}
	n := atomic.AddUint64(&simpleIPCounter, 1)
	return p.targetIPs[int(n)%len(p.targetIPs)]
}

// dialSimpleWS 为一个目标地址开一条新的 WebSocket 并完成 CONNECT 握手。
func dialSimpleWS(target string) (net.Conn, error) {
	// 直连模式：每次新建 WebSocket（与 ech-wk 客户端行为一致）。
	// 预热池（含 dialGate 并发闸门）在 CF 简易服务端下既可能发出
	// "已被服务端悄悄关掉的死连接"，又会把并发握手限死在 6 条 ——
	// YouTube 这种多连接大流量一上来就被卡在并发闸门上，吞吐上不去。
	return dialSimpleWSTimeout(target, simpleConnectTimeout)
}

func dialSimpleWSTimeout(target string, timeout time.Duration) (net.Conn, error) {
	if echPool == nil {
		return nil, errors.New("连接池未初始化")
	}

	// 完全绕过预热池与并发闸门，每次全新建连（ech-wk 等价路径）。
	ws, err := echPool.dialWebSocketWithECH(echPool.wsServerAddr, 2, echPool.pickIP(), "", 0)
	if err != nil {
		return nil, err
	}

	// 首帧留空：那个字段在服务端会过 TextEncoder，塞二进制进去必然被改写。
	// 真正的数据等 CONNECTED 之后用二进制帧发。
	_ = ws.SetWriteDeadline(time.Now().Add(timeout))
	if err := ws.WriteMessage(websocket.TextMessage, []byte("CONNECT:"+target+"|")); err != nil {
		_ = ws.Close()
		return nil, fmt.Errorf("发送 CONNECT 失败: %w", err)
	}

	// 等服务端确认。服务端在这一步可能直接回 ERROR:（目标连不上等）
	_ = ws.SetReadDeadline(time.Now().Add(timeout))
	for {
		mt, data, err := ws.ReadMessage()
		if err != nil {
			_ = ws.Close()
			return nil, fmt.Errorf("等待 CONNECTED 失败: %w", err)
		}
		if mt != websocket.TextMessage {
			// 理论上不该在 CONNECTED 之前收到二进制，收到就当它是数据，继续等
			continue
		}
		text := string(data)
		switch {
		case text == "CONNECTED":
			_ = ws.SetReadDeadline(time.Time{})
			_ = ws.SetWriteDeadline(time.Time{})
			conn := &simpleWSConn{ws: ws}
			go watchNoDataTimeout(conn, target)
			return conn, nil
		case strings.HasPrefix(text, "ERROR:"):
			_ = ws.Close()
			return nil, fmt.Errorf("服务端拒绝: %s", strings.TrimPrefix(text, "ERROR:"))
		case text == "CLOSE":
			_ = ws.Close()
			return nil, errors.New("服务端主动关闭")
		}
	}
}

// watchNoDataTimeout 兜底"假成功"隧道：客户端已发过数据（wroteAt != 0）、
// 服务端却一直没回（readData 仍 false），超过时限即判定黑洞（出站数据被堵 /
// Worker 兼容日期不对），主动断开，免得连接在 relayOutbound 的 io.Copy 里
// 永久挂起。客户端还没发数据的空闲连接不受影响；正常连接服务端毫秒级就有
// 回应（TLS 握手），一旦收到过数据本函数立即退出。
func watchNoDataTimeout(c *simpleWSConn, target string) {
	const noDataTimeout = 8 * time.Second
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for range ticker.C {
		if c.closed.Load() || c.readData.Load() {
			return
		}
		wrote := c.wroteAt.Load()
		if wrote == 0 {
			continue
		}
		if time.Since(time.Unix(0, wrote)) > noDataTimeout {
			log.Printf("[隧道] %s 已发数据但 %.0f 秒内服务端从未返回，疑似服务端黑洞，已断开（可检查 Worker 兼容日期是否 ≥ 2025-09-15）", target, noDataTimeout.Seconds())
			_ = c.ws.Close()
			return
		}
	}
}

// probeSimpleProtocol 探测服务端是不是这种「简易 WebSocket 代理」。
// 拿一个必然存在的目标试一次 CONNECT，能收到 CONNECTED 就说明是。
func probeSimpleProtocol() bool {
	if echPool == nil {
		return false
	}
	ws, err := echPool.dialWebSocketWithECH(echPool.wsServerAddr, 1, echPool.pickIP(), "", 0)
	if err != nil {
		return false
	}
	defer ws.Close()

	// 探测目标特意避开 Cloudflare 自家网段：Worker 的 connect() 不允许连回 CF，
	// 拿 1.1.1.1 去探会稳定收到 ERROR，白白误导判断。
	// 超时给足 10s：ECH 查询 + TLS 握手 + WS 升级可能就要好几秒，
	// 之前 4s 在 DoH 刚恢复/链路慢时不够，探测误判成 smux → simple 服务端黑洞。
	_ = ws.SetWriteDeadline(time.Now().Add(10 * time.Second))
	if err := ws.WriteMessage(websocket.TextMessage, []byte("CONNECT:8.8.8.8:53|")); err != nil {
		return false
	}

	_ = ws.SetReadDeadline(time.Now().Add(10 * time.Second))
	mt, data, err := ws.ReadMessage()
	if err != nil {
		// 没有任何回应 —— x-tunnel 服务端就是这个反应，它在等 smux 帧
		return false
	}
	if mt != websocket.TextMessage {
		return false
	}
	text := string(data)
	// CONNECTED 固然是肯定答复，ERROR: 同样说明服务端读懂了 CONNECT 指令，
	// 只是那个目标它连不上而已 —— 两者都足以判定这是简易 WebSocket 代理。
	return text == "CONNECTED" || strings.HasPrefix(text, "ERROR:")
}

