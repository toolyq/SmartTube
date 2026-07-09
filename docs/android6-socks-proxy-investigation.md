# Android 6 SOCKS Proxy Investigation

Date: 2026-07-10

## Background

Issue context: Android 6 devices fail when SmartTube uses a SOCKS proxy, while Android 14 reportedly works. HTTP/HTTPS proxy works, but SOCKS initially failed with errors such as:

- `hostname is unresolved`
- `socket closed`
- `UnknownHostException` wrapped at `RetrofitHelper.java:127`
- Settings proxy test succeeds, but homepage fails until the proxy settings test is run once

The important observation is that the settings proxy test and the homepage use different network paths. The settings test creates or refreshes the shared OkHttp path immediately, while homepage API calls commonly go through cached Retrofit service objects.

## Main Root Causes

1. Android 6 SOCKS implementation cannot reliably handle unresolved hostnames through OkHttp's normal SOCKS path.

   For SOCKS5 remote DNS, the destination hostname must be sent to the proxy as a domain name. Android 6 can instead fail locally before the SOCKS proxy gets a chance to resolve the host.

2. TLS wrapping on old Android can close or mishandle the custom SOCKS socket wrapper.

   The TLS socket factory needs to unwrap the underlying delegate socket before SSL wrapping.

3. Retrofit clients and API interfaces were cached across proxy changes.

   `OkHttpManager.unhold()` was not enough because `RetrofitOkHttpHelper.client` used `by lazy`, and many services store `RetrofitHelper.create(...)` results in fields.

4. Startup proxy initialization did not reset clients.

   Cold start only called `ProxyManager.configureSystemProxy()`. Visiting the settings proxy screen worked because that path additionally reset OkHttp and Retrofit clients.

## Changes Made

### 1. Build Script

File: `build.bat`

Purpose: make `build.bat stable debug` behave correctly.

Change summary:

- Collects extra Gradle arguments after consuming flavor and build type.
- Prevents `stable` and `debug` from being forwarded as Gradle task names.
- Gradle call now uses `%EXTRA_GRADLE_ARGS%` instead of raw `%*`.

Why:

Before this change, `build.bat stable debug` could produce Gradle errors like `Task 'stable' not found`.

### 2. OkHttp SOCKS Remote DNS

Files, both copies should stay in sync:

- `SharedModules/sharedutils/src/main/java/com/liskovsoft/sharedutils/okhttp/OkHttpCommons.java`
- `MediaServiceCore/SharedModules/sharedutils/src/main/java/com/liskovsoft/sharedutils/okhttp/OkHttpCommons.java`
- `SharedModules/sharedutils/src/main/java/com/liskovsoft/sharedutils/okhttp/SocksProxySocketFactory.java`
- `MediaServiceCore/SharedModules/sharedutils/src/main/java/com/liskovsoft/sharedutils/okhttp/SocksProxySocketFactory.java`

Change summary:

- `OkHttpCommons.setupBuilder(...)` now applies proxy setup.
- SOCKS proxy setup uses:
  - `builder.proxy(Proxy.NO_PROXY)`
  - `builder.socketFactory(new SocksProxySocketFactory(...))`
  - `builder.dns(SocksProxySocketFactory.REMOTE_DNS)`
- HTTP/HTTPS proxy still uses normal `builder.proxy(new Proxy(...))` behavior.
- Added `SocksProxySocketFactory` for SOCKS5 CONNECT with hostname ATYP, so DNS resolution happens on the SOCKS proxy side.
- Supports no-auth and username/password SOCKS5 authentication.

Why:

This avoids Android 6 local DNS resolution for SOCKS destinations and gives SOCKS5h-style behavior.

### 3. TLS Socket Unwrap

Files, both copies should stay in sync:

- `SharedModules/sharedutils/src/main/java/com/liskovsoft/sharedutils/okhttp/Tls12SocketFactory.java`
- `MediaServiceCore/SharedModules/sharedutils/src/main/java/com/liskovsoft/sharedutils/okhttp/Tls12SocketFactory.java`

Change summary:

- `createSocket(Socket s, String host, int port, boolean autoClose)` now wraps `SocksProxySocketFactory.unwrap(s)`.

Why:

Android 6 TLS wrapping can fail or close the wrapper socket. Unwrapping passes the real delegate socket to the platform SSL implementation.

### 4. Proxy Settings Test Path

File: `common/src/main/java/com/liskovsoft/smartyoutubetv2/common/proxy/WebProxyDialog.java`

Change summary:

- Added `resetHttpClients()`:
  - `OkHttpManager.unhold()`
  - `RetrofitOkHttpHelper.unhold()`
- Calls this reset when:
  - proxy is enabled/disabled from the dialog
  - proxy test starts after saving settings
  - dialog closes and applies proxy configuration
- The proxy test uses `OkHttpManager.instance().getClient()` after the reset.

Why:

Proxy changes must recreate clients. Existing clients may have been built before system proxy properties were updated.

### 5. General Settings Proxy Toggle

File: `common/src/main/java/com/liskovsoft/smartyoutubetv2/common/app/presenters/settings/GeneralSettingsPresenter.java`

Change summary:

- When the proxy toggle changes, it now resets both:
  - `OkHttpManager`
  - `RetrofitOkHttpHelper`

Why:

The proxy enable/disable path should behave like the proxy dialog path and should not leave Retrofit clients stale.

### 6. Cold Startup Proxy Initialization

File: `common/src/main/java/com/liskovsoft/smartyoutubetv2/common/app/presenters/SplashPresenter.java`

Change summary:

- During `initProxy()`, if proxy is enabled:
  - calls `new ProxyManager(getContext()).configureSystemProxy()`
  - then calls `OkHttpManager.unhold()`
  - then calls `RetrofitOkHttpHelper.unhold()`

Why:

This fixes the case where direct cold startup fails, but visiting the proxy settings test first makes homepage work. Startup now performs the same network client reset as settings/test paths.

### 7. Retrofit OkHttp Client Reset

File: `MediaServiceCore/youtubeapi/src/main/java/com/liskovsoft/googlecommon/common/helpers/RetrofitOkHttpHelper.kt`

Change summary:

- Replaced immutable `by lazy` client with a resettable cached client.
- Added `clientGeneration` counter.
- Added `unhold()` that:
  - cancels outstanding requests
  - evicts the connection pool
  - clears cached client
  - clears auth skip list
  - increments generation

Why:

Retrofit uses this OkHttp client for YouTube API calls. It must be rebuilt after proxy configuration changes.

### 8. Resettable Retrofit API Interfaces

File: `MediaServiceCore/youtubeapi/src/main/java/com/liskovsoft/googlecommon/common/helpers/RetrofitHelper.java`

Change summary:

- `RetrofitHelper.create(Class<T>)` now returns a dynamic proxy.
- The proxy stores a delegate API object plus the `RetrofitOkHttpHelper.clientGeneration` used to create it.
- On each method call, it checks the current generation.
- If generation changed, it rebuilds the underlying Retrofit API using the current OkHttp client.

Why:

Many services cache Retrofit API interfaces in fields, for example:

- `BrowseService2`
- `WatchNextService`
- `VisitorService`
- `HTTPClient`
- `SearchService2`
- comments, chat, notifications, constants, etc.

Resetting only `RetrofitOkHttpHelper.client` does not affect Retrofit interfaces already built with the old client. The dynamic proxy makes existing service fields automatically switch to a fresh Retrofit delegate after proxy changes.

## Important Behavior Notes

- Settings proxy test success proves the custom SOCKS path works.
- Homepage failure after settings test success usually means a stale Retrofit client/API path.
- Homepage failure only on cold startup means startup proxy initialization did not reset network clients.
- `RetrofitHelper.java:127` is where `IOException` is wrapped after `Call.execute()`. It is a symptom location, not the root cause by itself.

## Validation Commands

Compile affected modules:

```powershell
.\gradlew.bat :common:compileStstableDebugJavaWithJavac :youtubeapi:compileStstableDebugKotlin :youtubeapi:compileStstableDebugJavaWithJavac
```

Build stable debug APK:

```powershell
.\build.bat stable debug
```

Expected APK:

```text
smarttubetv/build/outputs/apk/ststable/debug/SmartTube_stable_32.02_universal.apk
```

For Android 6 testing, install the universal APK first.

## Test Matrix

Recommended manual checks:

1. Fresh install or clear app data.
2. Configure SOCKS proxy.
3. Force stop the app.
4. Launch directly into homepage without visiting proxy settings.
5. Confirm homepage loads through SOCKS.
6. Open proxy settings and run test.
7. Return to homepage and confirm it still works.
8. Toggle proxy off and on again, then confirm clients are recreated.
9. Test HTTP/HTTPS proxy to verify non-SOCKS path was not regressed.

## If It Still Fails

Collect these details:

- Full stack trace above `RetrofitHelper.java:127`.
- The unresolved hostname from `UnknownHostException`.
- Whether failure happens:
  - only on cold startup
  - only before settings proxy test
  - after proxy toggle
  - during image loading
  - during video playback
- Whether the failing request is Retrofit, Glide, WebView, ExoPlayer, or direct `OkHttpManager`.

Potential remaining paths to inspect:

- Glide image loading, because thumbnails may use Glide's own loader.
- WebView/potoken flows, because WebView proxy behavior is separate from OkHttp.
- ExoPlayer data source, though OkHttp data source already uses `OkHttpManager.instance().getClient()`.
- Any code path using raw `URLConnection` or platform DNS outside OkHttp/Retrofit.

## Repository Structure Warning

There are sharedutils copies in both locations:

- `SharedModules/sharedutils/...`
- `MediaServiceCore/SharedModules/sharedutils/...`

When changing OkHttp/SOCKS/TLS behavior, keep both copies synchronized unless the build is confirmed to use only one of them.

## Current Outcome

At the time of this note:

- SOCKS proxy test in settings succeeds.
- Retrofit paths have resettable clients and resettable API delegates.
- Startup proxy initialization now resets OkHttp and Retrofit clients.
- Build command succeeds and produces the universal APK.
