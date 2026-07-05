import XCTest
@testable import PgAgentApp

// Tests for the paste-to-connect parser (roadmap 2.1): postgres:// URLs,
// keyword=value DSNs, and the ~/.pgpass / ~/.pg_service.conf importers.
// The password-separation rule matters most: a parsed password must never
// end up inside the produced PostgresProfile.
final class PostgresConnectionURLTests: XCTestCase {

    // MARK: - URL form basics

    func testBasicPostgresURL() throws {
        let parsed = try PostgresConnectionURL.parse(
            "postgres://alice:secret@db.example.com:5433/appdb"
        )
        XCTAssertEqual(parsed.host, "db.example.com")
        XCTAssertEqual(parsed.port, 5433)
        XCTAssertEqual(parsed.database, "appdb")
        XCTAssertEqual(parsed.user, "alice")
        XCTAssertEqual(parsed.password, "secret")
        XCTAssertNil(parsed.tls)
    }

    func testPostgresqlSchemeAccepted() throws {
        let parsed = try PostgresConnectionURL.parse("postgresql://bob@host.internal/db1")
        XCTAssertEqual(parsed.user, "bob")
        XCTAssertEqual(parsed.host, "host.internal")
        XCTAssertEqual(parsed.database, "db1")
        XCTAssertEqual(parsed.port, 5432, "port defaults to 5432")
        XCTAssertNil(parsed.password)
    }

    func testDefaultDatabaseFallsBackToUserThenPostgres() throws {
        let withUser = try PostgresConnectionURL.parse("postgres://carol@h")
        XCTAssertEqual(withUser.database, "carol", "libpq behavior: dbname defaults to user")

        let noUser = try PostgresConnectionURL.parse("postgres://h:5432")
        XCTAssertEqual(noUser.database, "postgres")
        XCTAssertEqual(noUser.user, "")
    }

    // MARK: - Percent-encoded credentials

    func testPercentEncodedPasswordIsDecoded() throws {
        let parsed = try PostgresConnectionURL.parse(
            "postgres://user:p%40ss%2Fw%3Ard%25@host/db"
        )
        XCTAssertEqual(parsed.password, "p@ss/w:rd%")
    }

    func testPercentEncodedUserIsDecoded() throws {
        let parsed = try PostgresConnectionURL.parse("postgres://user%2Bteam@host/db")
        XCTAssertEqual(parsed.user, "user+team")
    }

    // MARK: - IPv6

    func testIPv6HostWithBrackets() throws {
        let parsed = try PostgresConnectionURL.parse(
            "postgres://admin:pw@[2001:db8::1]:6432/metrics"
        )
        XCTAssertEqual(parsed.host, "2001:db8::1")
        XCTAssertEqual(parsed.port, 6432)
        XCTAssertEqual(parsed.database, "metrics")
    }

    func testIPv6LoopbackDefaultPort() throws {
        let parsed = try PostgresConnectionURL.parse("postgres://u@[::1]/db")
        XCTAssertEqual(parsed.host, "::1")
        XCTAssertEqual(parsed.port, 5432)
    }

    // MARK: - Query parameters

    func testSslModeMappingToProfileTls() throws {
        func tls(_ mode: String) throws -> PostgresTlsMode? {
            try PostgresConnectionURL.parse("postgres://u@h/db?sslmode=\(mode)").tls
        }
        XCTAssertEqual(try tls("disable"), .disable)
        XCTAssertEqual(try tls("allow"), .prefer)
        XCTAssertEqual(try tls("prefer"), .prefer)
        XCTAssertEqual(try tls("require"), .require)
        // verify-ca maps UP to verify_full — never silently downgrade a
        // verification request the user pasted.
        XCTAssertEqual(try tls("verify-ca"), .verifyFull)
        XCTAssertEqual(try tls("verify-full"), .verifyFull)
    }

    func testUnknownSslModeThrows() {
        XCTAssertThrowsError(
            try PostgresConnectionURL.parse("postgres://u@h/db?sslmode=bogus")
        ) { error in
            XCTAssertEqual(
                error as? PostgresConnectionURLError, .unknownSslMode("bogus")
            )
        }
    }

    func testApplicationNameAndTimeoutAndUnknownParamsIgnoredGracefully() throws {
        let parsed = try PostgresConnectionURL.parse(
            "postgres://u:p@h/db?application_name=myapp&connect_timeout=7&options=-csearch_path%3Dpublic&channel_binding=require"
        )
        XCTAssertEqual(parsed.applicationName, "myapp")
        XCTAssertEqual(parsed.connectTimeoutSecs, 7)
    }

    // MARK: - DSN keyword form

    func testBasicDSN() throws {
        let parsed = try PostgresConnectionURL.parse(
            "host=10.0.0.5 port=5433 dbname=warehouse user=etl password=hunter2 sslmode=require"
        )
        XCTAssertEqual(parsed.host, "10.0.0.5")
        XCTAssertEqual(parsed.port, 5433)
        XCTAssertEqual(parsed.database, "warehouse")
        XCTAssertEqual(parsed.user, "etl")
        XCTAssertEqual(parsed.password, "hunter2")
        XCTAssertEqual(parsed.tls, .require)
    }

    func testDSNQuotedValueWithEscapes() throws {
        // password='it\'s a \\ pass word' → it's a \ pass word
        let parsed = try PostgresConnectionURL.parse(
            "host=h dbname=db user=u password='it\\'s a \\\\ pass word'"
        )
        XCTAssertEqual(parsed.password, "it's a \\ pass word")
    }

    func testDSNDefaultsAndSpacesAroundEquals() throws {
        let parsed = try PostgresConnectionURL.parse("dbname = app user = svc")
        XCTAssertEqual(parsed.host, "127.0.0.1", "host defaults to loopback")
        XCTAssertEqual(parsed.port, 5432)
        XCTAssertEqual(parsed.database, "app")
        XCTAssertEqual(parsed.user, "svc")
    }

    func testDSNBracketedIPv6Host() throws {
        let parsed = try PostgresConnectionURL.parse("host=[::1] dbname=db user=u")
        XCTAssertEqual(parsed.host, "::1")
    }

    // MARK: - Malformed input

    func testGarbageInputThrows() {
        XCTAssertThrowsError(try PostgresConnectionURL.parse("not a connection string")) { error in
            // "not"/"a"/"connection" contain no '=', so this is rejected as
            // not-a-connection-string rather than a keyword-pair error.
            XCTAssertEqual(error as? PostgresConnectionURLError, .notAConnectionString)
        }
        XCTAssertThrowsError(try PostgresConnectionURL.parse("   "))
        XCTAssertThrowsError(try PostgresConnectionURL.parse("mysql://u@h/db")) { error in
            XCTAssertEqual(
                error as? PostgresConnectionURLError, .unsupportedScheme("mysql")
            )
        }
        XCTAssertThrowsError(try PostgresConnectionURL.parse("postgres://u@h:notaport/db"))
        XCTAssertThrowsError(try PostgresConnectionURL.parse("host=h port=99999 dbname=d")) { error in
            XCTAssertEqual(error as? PostgresConnectionURLError, .invalidPort("99999"))
        }
    }

    func testPlausibleProbe() {
        XCTAssertTrue(PostgresConnectionURL.plausible("postgres://u:p@h/db"))
        XCTAssertFalse(PostgresConnectionURL.plausible("just some pasted prose"))
        XCTAssertFalse(PostgresConnectionURL.plausible(""))
    }

    // MARK: - Profile conversion keeps the password out

    func testMakeProfileNeverContainsPassword() throws {
        let parsed = try PostgresConnectionURL.parse(
            "postgres://alice:supersecret@db.example.com/appdb?sslmode=verify-full"
        )
        let profile = parsed.makeProfile()
        XCTAssertEqual(profile.host, "db.example.com")
        XCTAssertEqual(profile.database, "appdb")
        XCTAssertEqual(profile.user, "alice")
        XCTAssertEqual(profile.tls, .verifyFull)
        XCTAssertEqual(profile.auth, .keychain, "password is staged for the keychain, not the profile")
        XCTAssertEqual(profile.keychainAccount, "alice@db.example.com:5432/appdb")

        // Belt and braces: the encoded profile must not contain the secret.
        let encoded = try JSONEncoder().encode(profile)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("supersecret"))
    }

    func testMakeProfileDefaultsTlsToRequire() throws {
        let profile = try PostgresConnectionURL.parse("postgres://u@h/db").makeProfile()
        XCTAssertEqual(profile.tls, .require)
    }
}

// MARK: - ~/.pgpass

final class PostgresPgPassParserTests: XCTestCase {

    func testConcreteEntryParsed() {
        let entries = PostgresLocalConfig.parsePgPass(
            "db.example.com:5433:appdb:alice:s3cret\n"
        )
        XCTAssertEqual(entries, [
            PostgresLocalConfig.PgPassEntry(
                host: "db.example.com", port: 5433, database: "appdb",
                user: "alice", password: "s3cret"
            )
        ])
    }

    func testCommentsAndBlankLinesSkipped() {
        let text = """
        # my credentials
        \n
        localhost:5432:db1:me:pw1
        """
        XCTAssertEqual(PostgresLocalConfig.parsePgPass(text).count, 1)
    }

    func testBackslashEscapes() {
        // Password "a:b\c" and user "we:ird" written with pgpass escapes.
        let entries = PostgresLocalConfig.parsePgPass(
            #"h:5432:db:we\:ird:a\:b\\c"#
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].user, "we:ird")
        XCTAssertEqual(entries[0].password, #"a:b\c"#)
    }

    func testWildcardHostOrUserSkipped() {
        let text = """
        *:*:*:*:everywherepw
        *:5432:db:me:pw
        h:5432:db:*:pw
        """
        XCTAssertTrue(PostgresLocalConfig.parsePgPass(text).isEmpty,
                      "entries without a concrete host+user can't become profiles")
    }

    func testWildcardPortAndDatabaseGetDefaults() {
        let entries = PostgresLocalConfig.parsePgPass("h:*:*:me:pw")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].port, 5432)
        XCTAssertEqual(entries[0].database, "postgres")
    }

    func testMalformedLinesSkipped() {
        let text = """
        only:three:fields
        h:badport:db:me:pw
        h:5432:db:me:
        """
        XCTAssertTrue(PostgresLocalConfig.parsePgPass(text).isEmpty)
    }
}

// MARK: - ~/.pg_service.conf

final class PostgresPgServiceConfParserTests: XCTestCase {

    func testSectionsParsedWithDefaults() {
        let text = """
        # comment
        [prod]
        host=db.prod.example.com
        port=6432
        dbname=orders
        user=app
        password=pw1
        sslmode=verify-full

        [minimal]
        host=10.1.2.3
        """
        let entries = PostgresLocalConfig.parsePgServiceConf(text)
        XCTAssertEqual(entries.count, 2)

        XCTAssertEqual(entries[0].name, "prod")
        XCTAssertEqual(entries[0].host, "db.prod.example.com")
        XCTAssertEqual(entries[0].port, 6432)
        XCTAssertEqual(entries[0].database, "orders")
        XCTAssertEqual(entries[0].user, "app")
        XCTAssertEqual(entries[0].password, "pw1")
        XCTAssertEqual(entries[0].tls, .verifyFull)

        XCTAssertEqual(entries[1].name, "minimal")
        XCTAssertEqual(entries[1].port, 5432)
        XCTAssertEqual(entries[1].database, "postgres")
        XCTAssertEqual(entries[1].user, "postgres")
        XCTAssertNil(entries[1].password)
        XCTAssertNil(entries[1].tls)
    }

    func testSectionWithoutHostSkipped() {
        let text = """
        [broken]
        dbname=nohost

        [ok]
        host=h
        """
        let entries = PostgresLocalConfig.parsePgServiceConf(text)
        XCTAssertEqual(entries.map(\.name), ["ok"])
    }

    func testUnknownSslModeDoesNotSinkEntry() {
        let entries = PostgresLocalConfig.parsePgServiceConf(
            "[s]\nhost=h\nsslmode=weird\n"
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].tls)
    }

    func testValuesMayContainEqualsAndSpaces() {
        let entries = PostgresLocalConfig.parsePgServiceConf(
            "[s]\nhost=h\npassword=a=b c\n"
        )
        XCTAssertEqual(entries[0].password, "a=b c")
    }
}
