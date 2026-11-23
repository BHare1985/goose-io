# Spec Delta

## ADDED Requirements

### Requirement: Library operations are distinct from application operations
The core operations other than `serve` and `stop` SHALL be the library operations, the ones a library may call; `serve` and `stop` SHALL be the application's. The contract package SHALL offer a compile-time check, `require_library`, that names every library operation of the core, so that something that presents the contract to a library need not supply `serve` or `stop`.

#### Scenario: The library check
- **WHEN** a type that supplies every core operation except `serve` and `stop` is passed to `require_library`
- **THEN** it compiles, and a type that lacks `send` gets an error naming `send`

#### Scenario: The application operations stay the application's
- **WHEN** a library is built against a type that does not supply `stop`
- **THEN** a call to `stop` in the library fails to compile and the error names `stop`
