using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public sealed class FleetByobProxy : IDisposable
{
    private readonly int _listenPort;
    private readonly int _backendPort;
    private readonly string _idJson;
    private readonly TcpListener _v4;
    private readonly TcpListener _v6;
    private volatile bool _running;
    private volatile bool _shutdownRequested;

    public bool ShutdownRequested
    {
        get { return _shutdownRequested; }
    }

    public FleetByobProxy(int listenPort, int backendPort, string idJson)
    {
        _listenPort = listenPort;
        _backendPort = backendPort;
        _idJson = idJson;
        _v4 = new TcpListener(IPAddress.Loopback, listenPort);
        try
        {
            _v6 = new TcpListener(IPAddress.IPv6Loopback, listenPort);
        }
        catch (SocketException)
        {
            _v6 = null;
        }
    }

    public void Start()
    {
        _running = true;
        _v4.Start();
        if (_v6 != null)
        {
            try
            {
                _v6.Start();
            }
            catch (SocketException)
            {
                // IPv6 loopback may be unavailable on IPv4-only hosts.
            }
        }

        StartAcceptLoop(_v4);
        if (_v6 != null && _v6.Server.IsBound)
        {
            StartAcceptLoop(_v6);
        }
    }

    private void StartAcceptLoop(TcpListener listener)
    {
        Thread t = new Thread(delegate()
        {
            while (_running)
            {
                TcpClient client = null;
                try
                {
                    client = listener.AcceptTcpClient();
                }
                catch (SocketException)
                {
                    break;
                }
                catch (ObjectDisposedException)
                {
                    break;
                }

                if (client != null)
                {
                    TcpClient accepted = client;
                    ThreadPool.QueueUserWorkItem(delegate(object state)
                    {
                        HandleClient(accepted);
                    });
                }
            }
        });
        t.IsBackground = true;
        t.Start();
    }

    private bool IsLoopbackClient(TcpClient client)
    {
        try
        {
            IPEndPoint ep = client.Client.RemoteEndPoint as IPEndPoint;
            return ep != null && IPAddress.IsLoopback(ep.Address);
        }
        catch
        {
            return false;
        }
    }

    private bool IsAllowedHost(string hostHeader)
    {
        if (string.IsNullOrEmpty(hostHeader))
        {
            return false;
        }
        string h = hostHeader.Trim().ToLowerInvariant();
        return h == ("localhost:" + _listenPort)
            || h == ("127.0.0.1:" + _listenPort)
            || h == ("[::1]:" + _listenPort);
    }

    private bool IsAllowedOrigin(string originHeader)
    {
        if (string.IsNullOrEmpty(originHeader))
        {
            return true;
        }
        string o = originHeader.Trim().TrimEnd('/').ToLowerInvariant();
        return o == ("http://localhost:" + _listenPort)
            || o == ("http://127.0.0.1:" + _listenPort)
            || o == ("http://[::1]:" + _listenPort);
    }

    private static string ExtractHeader(string headText, string headerName)
    {
        string[] lines = headText.Split(new string[] { "\r\n", "\n" }, StringSplitOptions.None);
        string prefix = headerName + ":";
        for (int i = 1; i < lines.Length; i++)
        {
            string line = lines[i];
            if (line.Length == 0)
            {
                break;
            }
            if (line.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            {
                return line.Substring(prefix.Length).Trim();
            }
        }
        return null;
    }

    private static void SendSimpleResponse(NetworkStream stream, int statusCode, string reason, string contentType, string body)
    {
        byte[] payload = Encoding.UTF8.GetBytes(body);
        string head = string.Format(
            "HTTP/1.1 {0} {1}\r\nContent-Type: {2}\r\nContent-Length: {3}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n",
            statusCode, reason, contentType, payload.Length);
        byte[] headBytes = Encoding.ASCII.GetBytes(head);
        stream.Write(headBytes, 0, headBytes.Length);
        stream.Write(payload, 0, payload.Length);
        stream.Flush();
    }

    private void HandleClient(TcpClient client)
    {
        try
        {
            if (!IsLoopbackClient(client))
            {
                client.Close();
                return;
            }

            client.ReceiveTimeout = 5000;
            NetworkStream clientStream = client.GetStream();
            byte[] buf = new byte[8192];
            int totalRead = 0;
            int headerEnd = -1;

            while (totalRead < buf.Length)
            {
                int n = clientStream.Read(buf, totalRead, buf.Length - totalRead);
                if (n <= 0)
                {
                    break;
                }
                totalRead += n;
                string partial = Encoding.ASCII.GetString(buf, 0, totalRead);
                headerEnd = partial.IndexOf("\r\n\r\n", StringComparison.Ordinal);
                if (headerEnd >= 0)
                {
                    break;
                }
            }

            if (totalRead <= 0)
            {
                client.Close();
                return;
            }

            client.ReceiveTimeout = 0;
            string headText = Encoding.ASCII.GetString(buf, 0, headerEnd >= 0 ? headerEnd : totalRead);
            int firstCrLf = headText.IndexOf("\r\n", StringComparison.Ordinal);
            string requestLine = firstCrLf > 0 ? headText.Substring(0, firstCrLf) : headText;
            string[] parts = requestLine.Split(' ');
            string method = parts.Length >= 1 ? parts[0].ToUpperInvariant() : "";
            string rawPath = parts.Length >= 2 ? parts[1] : "/";
            int qIdx = rawPath.IndexOf('?');
            string path = qIdx >= 0 ? rawPath.Substring(0, qIdx) : rawPath;

            if (path == "/__fleethacker/id" || path == "/__fleethacker/shutdown")
            {
                string host = ExtractHeader(headText, "Host");
                string origin = ExtractHeader(headText, "Origin");
                if (!IsAllowedHost(host) || !IsAllowedOrigin(origin))
                {
                    SendSimpleResponse(clientStream, 403, "Forbidden", "application/json", "{\"error\":\"forbidden\"}");
                    client.Close();
                    return;
                }

                if (path == "/__fleethacker/id")
                {
                    if (method != "GET")
                    {
                        SendSimpleResponse(clientStream, 405, "Method Not Allowed", "application/json", "{\"error\":\"method_not_allowed\"}");
                    }
                    else
                    {
                        SendSimpleResponse(clientStream, 200, "OK", "application/json", _idJson);
                    }
                    client.Close();
                    return;
                }

                if (method != "POST")
                {
                    SendSimpleResponse(clientStream, 405, "Method Not Allowed", "application/json", "{\"error\":\"method_not_allowed\"}");
                    client.Close();
                    return;
                }
                string shutdownHdr = ExtractHeader(headText, "X-FleetHacker-Shutdown");
                if (shutdownHdr != "1")
                {
                    SendSimpleResponse(clientStream, 403, "Forbidden", "application/json", "{\"error\":\"missing_shutdown_header\"}");
                    client.Close();
                    return;
                }
                SendSimpleResponse(clientStream, 200, "OK", "application/json", "{\"ok\":true}");
                _shutdownRequested = true;
                client.Close();
                return;
            }

            TcpClient backend = new TcpClient();
            try
            {
                backend.Connect(IPAddress.Loopback, _backendPort);
                NetworkStream backendStream = backend.GetStream();
                backendStream.Write(buf, 0, totalRead);
                backendStream.Flush();

                ManualResetEvent done = new ManualResetEvent(false);
                int openDirections = 2;

                Thread up = new Thread(delegate()
                {
                    CopyUntilClose(clientStream, backendStream, backend);
                    if (Interlocked.Decrement(ref openDirections) == 0) done.Set();
                });
                Thread down = new Thread(delegate()
                {
                    CopyUntilClose(backendStream, clientStream, client);
                    if (Interlocked.Decrement(ref openDirections) == 0) done.Set();
                });
                up.IsBackground = true;
                down.IsBackground = true;
                up.Start();
                down.Start();
                done.WaitOne();
            }
            finally
            {
                try { backend.Close(); } catch { }
                try { client.Close(); } catch { }
            }
        }
        catch
        {
            try { client.Close(); } catch { }
        }
    }

    private static void CopyUntilClose(Stream src, Stream dst, TcpClient dstClient)
    {
        byte[] buffer = new byte[16384];
        try
        {
            while (true)
            {
                int n = src.Read(buffer, 0, buffer.Length);
                if (n <= 0)
                {
                    break;
                }
                dst.Write(buffer, 0, n);
                dst.Flush();
            }
        }
        catch
        {
        }
        finally
        {
            try { dstClient.Client.Shutdown(SocketShutdown.Send); } catch { }
        }
    }

    public void Stop()
    {
        _running = false;
        try { _v4.Stop(); } catch { }
        if (_v6 != null)
        {
            try { _v6.Stop(); } catch { }
        }
    }

    public void Dispose()
    {
        Stop();
    }
}
