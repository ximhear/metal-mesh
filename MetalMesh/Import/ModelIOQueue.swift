import Foundation

/// Model I/O(및 그 아래 libusd) 호출을 한 번에 하나씩만 실행한다.
///
/// Apple의 USD 런타임은 여러 스레드에서 USD 파일을 동시에 처음 열면 플러그인 레지스트리에서
/// 널 포인터 역참조로 크래시한다(EXC_BAD_ACCESS in Sdf_GetExtension). 프로브와 로더 모두 이 액터를 거친다.
actor ModelIOQueue {
    static let shared = ModelIOQueue()

    func run<T: Sendable>(_ body: @Sendable () throws -> T) throws -> T {
        try body()
    }

    func run<T: Sendable>(_ body: @Sendable () -> T) -> T {
        body()
    }
}
