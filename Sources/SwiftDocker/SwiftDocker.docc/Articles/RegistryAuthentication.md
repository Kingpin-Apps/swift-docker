# Registry Authentication

Authenticate with public and private Docker registries to push and pull images.

## Overview

Docker uses the `X-Registry-Auth` HTTP header to pass registry credentials. The value is a base64url-encoded (no padding) JSON object. SwiftDocker provides two types that build this value for you, and a ``RegistryAuthMiddleware`` that injects it automatically on every request.

## Authenticating with a private registry

Create a ``RegistryAuth`` value and pass it to ``Docker/init(apiVersion:registryAuth:requestTimeout:additionalMiddlewares:)``:

```swift
let auth = RegistryAuth(
    username: "myuser",
    password: "s3cr3t",
    serverAddress: "registry.example.com"
)

let docker = try Docker(registryAuth: auth)
```

The middleware appends `X-Registry-Auth` to every outgoing request. Endpoints that don't use it simply carry an extra (ignored) header.

## Using an identity token

If you have already obtained an identity token from the `/auth` endpoint, use ``RegistryIdentityToken`` instead:

```swift
// First, authenticate to get a token
let authResult = try await docker.client.systemAuth(.init(
    body: .json(.init(
        username: "myuser",
        password: "s3cr3t",
        serveraddress: "registry.example.com"
    ))
)).ok.body.json

guard let token = authResult.identityToken else {
    fatalError("No identity token returned")
}

// Then reconnect with the token
let identityToken = RegistryIdentityToken(identityToken: token)
let authedDocker = try Docker(
    socketPath: "/var/run/docker.sock",
    registryAuth: nil,
    additionalMiddlewares: [try RegistryAuthMiddleware(token: identityToken)]
)
```

## Encoding credentials manually

Both ``RegistryAuth`` and ``RegistryIdentityToken`` expose an ``RegistryAuth/encodedValue()`` method that returns the base64url-encoded JSON string. You can use this to set the header yourself:

```swift
let auth = RegistryAuth(
    username: "myuser",
    password: "s3cr3t",
    serverAddress: "registry.example.com"
)
let encoded = try auth.encodedValue()
// e.g. "eyJ1c2VybmFtZSI6Im15dXNlciIsInBhc3N3b3JkIjoic...."
```

## Pulling a private image

Once authenticated, pull a private image with `imageCreate`:

```swift
let auth = RegistryAuth(
    username: "myuser",
    password: "s3cr3t",
    serverAddress: "registry.example.com"
)
let docker = try Docker(registryAuth: auth)

_ = try await docker.client.imageCreate(.init(
    query: .init(fromImage: "registry.example.com/myapp", tag: "latest")
)).ok

print("Image pulled successfully")
```

## Pushing an image

`imagePush` also requires `X-Registry-Auth`. With ``RegistryAuthMiddleware`` attached it is injected automatically:

```swift
let auth = RegistryAuth(
    username: "myuser",
    password: "s3cr3t",
    serverAddress: "registry.example.com"
)
let docker = try Docker(registryAuth: auth)

// Tag an existing local image
_ = try await docker.client.imageTag(.init(
    path: .init(name: "myapp:latest"),
    query: .init(repo: "registry.example.com/myapp", tag: "v1.0")
)).created

// Push
let pushBody = try await docker.client.imagePush(.init(
    path: .init(name: "registry.example.com/myapp"),
    query: .init(tag: "v1.0")
)).ok.body.applicationVnd_docker_rawStream

// Consume the progress stream
for try await _ in pushBody {}
print("Push complete")
```

## Docker Hub

Docker Hub's server address is `https://index.docker.io/v1/`:

```swift
let hubAuth = RegistryAuth(
    username: "dockerhubuser",
    password: "dockerhubpassword",
    serverAddress: "https://index.docker.io/v1/"
)
let docker = try Docker(registryAuth: hubAuth)
```

## Attaching middleware to an existing client

``RegistryAuthMiddleware`` conforms to `ClientMiddleware` and can be added to any middleware chain:

```swift
let auth = RegistryAuth(username: "u", password: "p", serverAddress: "r.example.com")
let middleware = try RegistryAuthMiddleware(auth: auth)

let docker = try Docker(
    socketPath: "/var/run/docker.sock",
    additionalMiddlewares: [middleware]
)
```
