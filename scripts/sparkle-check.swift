import CryptoKit
import Foundation

let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sparkle-check: \(message)\n".utf8))
    exit(1)
}

func decode(_ base64: String, _ what: String) -> Data {
    guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("\(what) is not base64")
    }
    return data
}

func read(_ path: String) -> Data {
    if path == "-" { return FileHandle.standardInput.readDataToEndOfFile() }
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    return data
}

func publicKey(_ base64: String) -> Curve25519.Signing.PublicKey {
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: decode(base64, "the public key")) else {
        fail("the public key is not an Ed25519 key")
    }
    return key
}

func verify(_ data: Data, signature: String, key: String) -> Bool {
    publicKey(key).isValidSignature(decode(signature, "the signature"), for: data)
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "public-key" where args.count == 2:
    let seed = decode(String(decoding: read(args[1]), as: UTF8.self), "the private key")
    guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
        fail("the private key is not a 32-byte Ed25519 seed")
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "verify-file" where args.count == 4:
    guard verify(read(args[1]), signature: args[2], key: args[3]) else { fail("the signature is not valid for \(args[1])") }

case "verify-appcast" where args.count == 7:
    let (feedPath, zipPath, key, version, build, prefix) = (args[1], args[2], args[3], args[4], args[5], args[6])
    guard let feed = try? XMLDocument(data: read(feedPath)) else { fail("\(feedPath) is not XML") }
    let items = (try? feed.nodes(forXPath: "//item")) ?? []
    guard items.count == 1, let item = items.first as? XMLElement else { fail("expected 1 item, found \(items.count)") }
    func text(_ name: String) -> String? {
        item.elements(forLocalName: name, uri: sparkleNamespace).first?.stringValue
    }
    guard text("shortVersionString") == version else { fail("the item's version is \(text("shortVersionString") ?? "missing"), not \(version)") }
    guard text("version") == build else { fail("the item's build is \(text("version") ?? "missing"), not \(build)") }
    guard let enclosure = item.elements(forName: "enclosure").first else { fail("the item has no enclosure") }
    let url = enclosure.attribute(forName: "url")?.stringValue
    guard url == prefix + "Navi.zip" else { fail("the enclosure URL is \(url ?? "missing"), not \(prefix)Navi.zip") }
    let zip = read(zipPath)
    guard enclosure.attribute(forName: "length")?.stringValue == String(zip.count) else { fail("the enclosure length does not match the zip") }
    guard let signature = enclosure.attribute(forLocalName: "edSignature", uri: sparkleNamespace)?.stringValue else {
        fail("the enclosure has no sparkle:edSignature")
    }
    guard verify(zip, signature: signature, key: key) else { fail("the signature is not valid for the zip with this public key") }

default:
    fail("usage: public-key <key-file> | verify-file <file> <signature> <public-key> | verify-appcast <appcast> <zip> <public-key> <version> <build> <url-prefix>")
}
