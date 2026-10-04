// Deliberately C++20-only: concepts do not exist in msvc's default c++14 mode,
// so this file compiles only if xmake actually passed /std:c++20 to cl.
#include <concepts>
#include <iostream>

template <std::integral T>
T add(T a, T b)
{
    return a + b;
}

int main()
{
    std::cout << "c++20 concepts compiled fine: 1 + 2 = " << add(1, 2) << std::endl;
    return 0;
}
