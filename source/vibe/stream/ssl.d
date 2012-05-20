﻿/**
	SSL/TLS stream implementation

	Copyright: © 2012 Sönke Ludwig
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module vibe.stream.ssl;

import vibe.core.log;
import vibe.crypto.ssl;
import vibe.stream.stream;

import deimos.openssl.bio;
import deimos.openssl.err;
import deimos.openssl.ssl;

import std.algorithm;
import std.conv;
import std.exception;

import core.stdc.string : strlen;


enum SslStreamState {
	Connecting,
	Accepting,
	Connected
}

class SslStream : Stream {
	private {
		Stream m_stream;
		SslContext m_sslCtx;
		SslStreamState m_state;
		BIO* m_bio;
		ssl_st* m_ssl;
	}

	this(Stream underlying, SslContext ctx, SslStreamState state)
	{
		m_stream = underlying;
		m_state = state;
		m_sslCtx = ctx;
		m_ssl = ctx.createClientCtx();

		m_bio = BIO_new(&s_bio_methods);
		enforce(m_bio !is null, "SSL failed: failed to create BIO structure.");
		m_bio.init_ = 1;
		m_bio.ptr = cast(void*)this;
		m_bio.shutdown = 0;

		SSL_set_bio(m_ssl, m_bio, m_bio);

		final switch (state) {
			case SslStreamState.Accepting:
				//SSL_set_accept_state(m_ssl);
				SSL_accept(m_ssl);
				break;
			case SslStreamState.Connecting:
				//SSL_set_connect_state(m_ssl);
				SSL_connect(m_ssl);
				break;
			case SslStreamState.Connected:
				break;
		}
	}

	~this()
	{
		BIO_free(m_bio);
	}

	@property bool empty()
	{
		return leastSize() == 0 && m_stream.empty;
	}

	@property ulong leastSize()
	{
		auto ret = SSL_pending(m_ssl);
		return ret > 0 ? ret : m_stream.empty ? 0 : 1;
	}

	@property bool dataAvailableForRead()
	{
		return SSL_pending(m_ssl) > 0 || m_stream.dataAvailableForRead;
	}

	void read(ubyte[] dst)
	{
		while( dst.length > 0 ){
			auto ret = SSL_read(m_ssl, dst.ptr, dst.length);
			enforce(ret != 0, "SSL_read was unsuccessful with ret 0");
			enforce(ret >= 0, "SSL_read returned an error: "~to!string(SSL_get_error(m_ssl, ret)));
			//logTrace("SSL read %d/%d", ret, dst.length);
			dst = dst[ret .. $];
		}
	}

	ubyte[] readLine(size_t max_bytes = 0, string linesep = "\r\n")
	{
		return readLineDefault(max_bytes, linesep);
	}

	ubyte[] readAll(size_t max_bytes = 0)
	{
		return readAllDefault(max_bytes);
	}

	void write(in ubyte[] bytes_, bool do_flush = true)
	{
		const(ubyte)[] bytes = bytes_;
		while( bytes.length > 0 ){
			auto ret = SSL_write(m_ssl, bytes.ptr, bytes.length);
			
			const(char)* file = null, data = null;
			int line;
			int flags;
			size_t eret;
			char[120] ebuf;
			while( (eret = ERR_get_error_line_data(&file, &line, &data, &flags)) != 0 ){
				ERR_error_string(eret, ebuf.ptr);
				logWarn("SSL error %s at %s:%d: %s", to!string(ebuf.ptr), to!string(file), line, flags & ERR_TXT_STRING ? to!string(data) : "-");
				if( flags & ERR_TXT_MALLOCED ) OPENSSL_free(cast(void*)data);
			}
			enforce(ret != 0, "SSL_write was unsuccessful with ret 0");
			enforce(ret >= 0, "SSL_write returned an error: "~to!string(SSL_get_error(m_ssl, ret)));
			logTrace("SSL write %s", cast(string)bytes[0 .. ret]);
			bytes = bytes[ret .. $];
		}
		if( do_flush ) flush();
	}

	void flush()
	{

	}

	void finalize()
	{
		logTrace("SslStream finalize");
		SSL_shutdown(m_ssl);
	}

	void write(InputStream stream, ulong nbytes = 0, bool do_flush = true)
	{
		writeDefault(stream, nbytes, do_flush);
	}
}

private extern(C)
{
	int onBioNew(BIO *b)
	{
		b.init_ = 0;
		b.num = -1;
		b.ptr = null;
		b.flags = 0;
		return 1;
	}

	int onBioFree(BIO *b)
	{
		if( !b ) return 0;
		if( b.shutdown ){
			//if( b.init && b.ptr ) b.ptr.stream.free();
			b.init_ = 0;
			b.flags = 0;
			b.ptr = null;
		}
		return 1;
	}

	int onBioRead(BIO *b, char *outb, int outlen)
	{
		SslStream stream = cast(SslStream)b.ptr;
		
		outlen = min(outlen, stream.m_stream.leastSize);
		stream.m_stream.read(cast(ubyte[])outb[0 .. outlen]);
		return outlen;
	}

	int onBioWrite(BIO *b, const(char) *inb, int inlen)
	{
		SslStream stream = cast(SslStream)b.ptr;
		stream.m_stream.write(inb[0 .. inlen]);
		return inlen;
	}

	int onBioCtrl(BIO *b, int cmd, int num, void *ptr)
	{
		SslStream stream = cast(SslStream)b.ptr;
		int ret = 1;

		switch(cmd){
			case BIO_CTRL_GET_CLOSE: ret = b.shutdown; break;
			case BIO_CTRL_SET_CLOSE:
				logTrace("SSL set close %d", num);
				b.shutdown = cast(int)num;
				break;
			case BIO_CTRL_PENDING:
				auto sz = stream.m_stream.leastSize;
				return sz <= int.max ? cast(int)sz : int.max;
			case BIO_CTRL_WPENDING: return 0;
			case BIO_CTRL_DUP:
			case BIO_CTRL_FLUSH:
				ret = 1;
				break;
			default:
				ret = 0;
				break;
		}
		return ret;
	}

	int onBioPuts(BIO *b, const(char) *s)
	{
		return onBioWrite(b, s, strlen(s));
	}
}

private BIO_METHOD s_bio_methods = {
	57, "SslStream",
	&onBioWrite,
	&onBioRead,
	&onBioPuts,
	null, // &onBioGets
	&onBioCtrl,
	&onBioNew,
	&onBioFree,
	null, // &onBioCallbackCtrl
};
