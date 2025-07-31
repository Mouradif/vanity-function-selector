# Vanity Function Selector

A (⚡️BLAZINGLY FAST!!) function selector miner (using the CPU) for EVM contracts that conform to the ABI specs.

## Installation

1. Clone the repo

```sh
$ git clone https://github.com/Mouradif/vanity-function-selector
```

2. Build

```sh
$ cd vanity-function-selector
$ zig build --release=fast
```

3. (Optional) Put the binary in a directory in your `$PATH`

```sh
# For example
$ mv zig-out/bin/vfs ~/.local/bin
```

## Usage

```sh
$ vfs
Usage: vfs <pattern> <function-name> [...ARG_TYPE]

Examples

# Will return a function mintXX() (where 'XX' is the brute-forced suffix) that has a selector starting with 0xaa
$ vfs 0xaa mint

# Use the character 'x' as a wildcard. The following is equivalent to just 0xaa
$ vfs 0xaaxxxxxx mint

# You can pass function argument types as subsequent arguments
$ vfs 0xf0f0 bridge address address uint256

# Or as a single argument if you have complex types like tuples or structs
$ vfs 0x00 swap "(address,address,uint256[]),(address,address,uint256[])"
```
