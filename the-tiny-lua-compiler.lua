--[[
  Today we're going to write a compiler for Lua 5.1 in Lua.
  But not just any compiler... a super duper easy and teeny tiny
  compiler! A compiler that is so small that if you remove all the
  comments this file would be ~1700 lines of actual code.

  The compiler will be able to tokenize, parse, and compile (almost)
  any Lua code you throw at it. It will even be able to compile itself!

  So, let's get started!

  ----------------------------------------------------------------------------

  Our journey will cover transforming Lua code into Lua bytecode, which the
  Lua Virtual Machine (VM) can understand and execute.

  Here's a quick breakdown of what we're doing:

   Tokenizer: Breaks down Lua code into tokens, the basic building blocks
    like numbers, strings, and keywords.

   Parser: Converts tokens into an Abstract Syntax Tree (AST), a tree
    representation showing the structure of the code.

   Code Generator: Transforms the AST into Lua VM instructions, the
    low-level commands that the Lua VM can execute.

   Compiler: Turns Lua VM instructions into Lua bytecode, ready for
    execution by the Lua VM.

  This process is a bit like translating a book from one language to another,
  then adapting it into a screenplay. Each step refines and transforms the
  content, making it ready for the final audience: the Lua VM.
--]]

--[[
Glossary:
  Token:
    The smallest element of programming language syntax that the compiler recognizes.
    Tokens are the building blocks of code, akin to words in a language, and include
    elements like numbers, strings, keywords (e.g., `if`, `while`), identifiers (variable names),
    and operators (`+`, `-`, `*`, `/`). The tokenizer, or lexical analyzer, scans the source code
    to identify and produce these tokens.

  AST (Abstract Syntax Tree):
    A hierarchical tree representation that outlines the grammatical structure of the code.
    Each node in the tree denotes a construct occurring in the source code. The AST is
    generated from the tokens produced by the tokenizer and serves as a crucial structure
    for further stages of compilation, such as optimization and code generation. It abstracts
    away the syntax details, focusing on the code's logical structure.

  VM (Virtual Machine):
    In the context of programming languages, a VM specifically refers to a runtime engine
    that executes bytecode or intermediate code. This VM is not to be confused with system
    virtual machines (like VirtualBox or VMWare) that emulate a full hardware system;
    it's a process virtual machine designed to execute code in a high-level, portable format.

  Bytecode:
    A form of instruction set designed for efficient execution by a software VM. Bytecode
    is more abstract than machine code and is not tied to any specific hardware architecture.
    It serves as an intermediate representation of the code, optimized for portability and
    quick execution. Bytecode is typically generated from the AST and is executed by the VM.
    Unlike human-readable source code or assembly language, bytecode is binary and is
    intended to be read and understood by the VM rather than humans.

  Proto (Function Prototype):
    In Lua, a function prototype is a data structure that contains metadata about a function,
    including its bytecode, the number of parameters it accepts, its local variables, and its
    upvalues (variables captured from the surrounding scope). The Lua VM uses this information
    to execute the function and manage its execution context. Each Lua function, whether
    defined in Lua or C, is represented internally by a function prototype.

  Scope:
    Defines the visibility and lifetime of variables and parameters in a program. In Lua,
    scope is determined by the location of variable declarations. Variables can be global,
    local, or upvalues. Global variables are accessible from anywhere in the code. Local
    variables have their visibility limited to the block where they are declared, enhancing
    modularity and preventing unintended modifications. Upvalues are local variables from
    an enclosing function's scope, which are captured by closures, allowing the closure to
    access and modify these variables even when the function is executed outside its original scope.
--]]

--[[
    ============================================================================
                                  (ﾉ◕ヮ◕)ﾉ*:･ﾟ✧
                              THE HELPER FUNCTIONS!
    ============================================================================

    Building a compiler from scratch necessitates a set of utility functions to
    streamline common tasks, enhancing both efficiency and readability. Below,
    we introduce two essential helper functions pivotal to our compiler's core
    functionality.
--]]

-- Converts a list to a lookup table for O(1) element lookups
local function createLookupTable(list)
  local lookup = {}
  for _, value in ipairs(list) do
    lookup[value] = true
  end
  return lookup
end

-- Constructs a trie for efficient prefix-based operator searches
local function makeTrie(ops)
  -- Initialize the trie
  local trie = {}
  for _, op in ipairs(ops) do
    local node = trie
    -- Split the operator into individual characters
    for char in op:gmatch(".") do
      node[char] = node[char] or {}
      node = node[char]
    end
    node.Value = op
  end
  return trie
end

-- Converts a string into a list of characters
local function stringToChars(str)
  local chars = {}
  for char in str:gmatch(".") do
    table.insert(chars, char)
  end
  return chars
end

-- Inserts all methods from a source table into a target table
local function insertValues(target, source)
  for key, value in pairs(source) do
    target[key] = value
  end
end

--[[
    ============================================================================
                                    (•_•)?!
                              TOKENIZER CONSTANTS
    ============================================================================

    Before diving into the tokenizer's implementation, let's explore the
    essential constants and lookup tables that will guide the tokenization
    process. These constants include Lua operators, escaped character
    sequences, reserved keywords, and Lua's boolean and nil constants.
    By defining these constants upfront, we can streamline the tokenization
    logic and ensure accurate identification and classification of tokens
    within the Lua code.
--]]

-- Lua operators for tokenization: arithmetic, comparison, logical.
local TOKENIZER_LUA_OPERATORS = {
  "^", "*", "/", "%",
  "+", "-", "<", ">",
  "#",

  "<=",  ">=", "==",  "~=",
  "and", "or", "not", ".."
}

-- Maps escaped sequences to characters for string literals.
local TOKENIZER_ESCAPED_CHARACTER_CONVERSIONS = {
  ["a"]  = "\a", -- bell
  ["b"]  = "\b", -- backspace
  ["f"]  = "\f", -- form feed
  ["n"]  = "\n", -- newline
  ["r"]  = "\r", -- carriage return
  ["t"]  = "\t", -- horizontal tab
  ["v"]  = "\v", -- vertical tab

  ["\\"] = "\\", -- backslash
  ["\""] = "\"", -- double quote
  ["\'"] = "\'", -- single quote
}

-- Lookup for Lua's boolean and nil constants.
local TOKENIZER_LUA_CONSTANTS_LOOKUP = createLookupTable({ "true", "false", "nil" })

-- Lookup for Lua's reserved keywords.
local TOKENIZER_RESERVED_KEYWORDS_LOOKUP = createLookupTable({
  "while",    "do",     "end",   "for",
  "local",    "repeat", "until", "return",
  "in",       "if",     "else",  "elseif",
  "function", "then",   "break"
})

-- Lookup for operators.
local TOKENIZER_LUA_OPERATORS_LOOKUP = createLookupTable(TOKENIZER_LUA_OPERATORS)

-- Trie for efficient operator searching.
local TOKENIZER_OPERATOR_TRIE = makeTrie(TOKENIZER_LUA_OPERATORS)

--[[
    ============================================================================
                                 (/^▽^)/
                              THE TOKENIZER!
    ============================================================================

    Imagine the tokenizer as a conveyor belt. You put Lua code in one end,
    and tokens come out the other end. The tokenizer will convert the input
    code into a list of tokens that the parser can understand.
    Tokens are the smallest building blocks of a programming language. They can be
    anything from a number, a string, a keyword, an identifier, or an operator.
    Typically, tokenizers strip out comments and whitespace, as they are not
    needed for the parsing phase, our tokenizer follows the same approach.

    Here's an example of how the tokenizer breaks down a simple Lua script:
    ```lua
    if (x == 10) then
      print("Hello, world!")
    end
    ```
    The resulting tokens would look like this:
    |-----------------|------------------|
    | Type            | Value            |
    |-----------------|------------------|
    | Keyword         | if               |
    | Character       | (                |
    | Identifier      | x                |
    | Operator        | ==               |
    | Number          | 10               |
    | Character       | )                |
    | Keyword         | then             |
    | Identifier      | print            |
    | Character       | (                |
    | String          | Hello, world!    |
    | Character       | )                |
    | Keyword         | end              |
    |-----------------|------------------|
--]]

--* TokenizerMethods *--
local TokenizerMethods = {}

--// Character Navigation //--

-- Looks ahead by n characters in the character stream
function TokenizerMethods:lookAhead(n)
  local updatedCharPos = self.curCharPos + n
  local updatedChar    = self.charStream[updatedCharPos]
  return updatedChar
end

-- Consumes (skips) n characters in the character stream
function TokenizerMethods:consume(n)
  local updatedCharPos = self.curCharPos + n
  local updatedChar    = self.charStream[updatedCharPos]
  self.curCharPos      = updatedCharPos
  self.curChar         = updatedChar
  return updatedChar
end

--// Character Checkers //--

-- Checks if a character is \t (tab), \n (newline), or \r (carriage return) 
function TokenizerMethods:isWhitespace(char)
  return char:match("%s")
end

-- Checks if a character is a digit (0-9)
function TokenizerMethods:isNumber(char)
  return char:match("%d")
end

-- Checks if a number is hexadecimal (0-9, a-f, A-F)
function TokenizerMethods:isHexadecimalNumber(char)
  return char:match("[%da-fA-F]")
end

-- Checks if a character is a letter, digit, or underscore
function TokenizerMethods:isIdentifier(char)
  return char:match("[%a%d_]")
end

-- Checks if a character is a letter or underscore
function TokenizerMethods:isIdentifierStart(char)
  return char:match("[%a_]")
end

function TokenizerMethods:isScientificNotationPrefix(char)
  return char == "e" or char == "E"
end

--// Multi-Character Checkers //--
function TokenizerMethods:isHexadecimalNumberPrefix()
  local nextChar = self:lookAhead(1)
  return self.curChar == "0" and (
    nextChar == "x" or nextChar == "X"
  )
end

function TokenizerMethods:isVarArg()
  return self.curChar == "."
         and self:lookAhead(1) == "."
         and self:lookAhead(2) == "."
end

function TokenizerMethods:isComment()
  return self.curChar == "-"
         and self:lookAhead(1) == "-"
end

function TokenizerMethods:isString()
  local curChar  = self.curChar
  local nextChar = self:lookAhead(1)
  return (curChar == '"' or curChar == "'")
      or (curChar == "[" and (nextChar == "[" or nextChar == "="))
end

--// Consumers //--
function TokenizerMethods:consumeWhitespace()
  local startChar = self.curChar
  local startPos  = self.curCharPos
  while self:lookAhead(1) == startChar do
    self:consume(1)
  end

  return self.code:sub(startPos, self.curCharPos)
end

function TokenizerMethods:consumeIdentifier()
  local start = self.curCharPos
  while self:isIdentifier(self:lookAhead(1)) do
    self:consume(1)
  end

  return self.code:sub(start, self.curCharPos)
end

function TokenizerMethods:consumeInteger(maxLength)
  local start = self.curCharPos
  while self:lookAhead(1):match("%d") do
    if (maxLength and (self.curCharPos - start) >= maxLength) then
      break
    end
    self:consume(1)
  end

  return self.code:sub(start, self.curCharPos)
end

function TokenizerMethods:consumeNumber()
  local start = self.curCharPos

  -- Hexadecimal number case
  -- 0[xX][0-9a-fA-F]+
  if self:isHexadecimalNumberPrefix() then
    self:consume(2)   -- Consume the "0x" part
    while self:isHexadecimalNumber(self:lookAhead(1)) do
      self:consume(1) -- Consume hexadecimal digits
    end
    return self.code:sub(start, self.curCharPos)
  end

  -- [0-9]*
  while self:isNumber(self:lookAhead(1)) do
    self:consume(1) -- Consume digits
  end

  -- Floating point number case
  -- \.[0-9]+
  if self:lookAhead(1) == "." then
    self:consume(1) -- Consume the "."
    while self:isNumber(self:lookAhead(1)) do
      self:consume(1)
    end
  end

  -- Exponential (scientific) notation case
  -- [eE][+-]?[0-9]+
  if self:isScientificNotationPrefix(self:lookAhead(1)) then
    self:consume(1)   -- Consume the "e" or "E"
    if self:lookAhead(1) == "+" or self:lookAhead(1) == "-" then
      self:consume(1) -- Consume optional sign
    end
    while self:isNumber(self:lookAhead(1)) do
      self:consume(1) -- Consume exponent digits
    end
  end

  return self.code:sub(start, self.curCharPos)
end

function TokenizerMethods:consumeSimpleString()
  local delimiter = self.curChar
  local newString = {}
  self:consume(1) -- Consume the delimiter
  while self.curChar ~= delimiter do
    if self.curChar == "\\" then
      local nextChar = self:consume(1)
      if nextChar:match("%d") then -- Numeric escape sequence?
        local number = self:consumeInteger(3)
        local luaNumber = tonumber(number)
        if not luaNumber then
          error("invalid escape sequence near '\\" .. number .. "'")
        end

        table.insert(newString, string.char(luaNumber))
      elseif TOKENIZER_ESCAPED_CHARACTER_CONVERSIONS[nextChar] then
        table.insert(newString, TOKENIZER_ESCAPED_CHARACTER_CONVERSIONS[nextChar])
      else
        error("invalid escape sequence near '\\" .. nextChar .. "'")
      end
    else
      table.insert(newString, self.curChar)
    end
    self:consume(1)
  end
  return table.concat(newString)
end

function TokenizerMethods:consumeLongString()
  self:consume(1) -- Consume the "[" character
  local start = self.curCharPos
  local depth = 0
  while self.curChar == "=" do
    self:consume(1) -- Consume the "=" character
    depth = depth + 1
  end
  if self.curChar ~= "[" then
    error("invalid long string delimiter")
  end

  self:consume(1) -- Consume the "[" character
  while true do
    if self.curChar == "]" then
      self:consume(1) -- Consume the "]" character
      local closingDepth = 0
      while self.curChar == "=" do
        self:consume(1) -- Consume the "=" character
        closingDepth = closingDepth + 1
      end
      if closingDepth == depth and self.curChar == "]" then
        -- Exit the loop, as the closing delimiter is fully matched
        break
      end
    elseif self.curChar == "\0" then
      error("Unclosed long comment")
    end

    self:consume(1)
  end

  return self.code:sub(start + depth + 1, self.curCharPos - 2 - depth)
end

function TokenizerMethods:consumeString()
  if self.curChar == "[" then
    return self:consumeLongString()
  end
  return self:consumeSimpleString()
end

function TokenizerMethods:consumeOperator()
  local node  = TOKENIZER_OPERATOR_TRIE
  local operator

  -- Trie walker
  local index = 0
  while true do
    local character = self:lookAhead(index)
    node = node[character] -- Advance to the deeper node
    if not node then break end
    operator = node.Value
    index    = index + 1
  end
  if not operator then return end
  self:consume(#operator - 1)
  return operator
end

function TokenizerMethods:consumeShortComment()
  local curChar = self.curChar
  while curChar ~= "\0" and curChar ~= "\n" do
    curChar = self:consume(1)
  end
end

function TokenizerMethods:consumeLongComment()
  self:consume(1) -- Consumes the "[" character
  local depth = 0
  while self.curChar == "=" do
    self:consume(1) -- Consume the "=" character
    depth = depth + 1
  end
  if self.curChar ~= "[" then return self:consumeShortComment() end
  while true do
    if self.curChar == "]" then
      self:consume(1) -- Consume the "]" character
      local closingDepth = 0
      while self.curChar == "=" do
        self:consume(1) -- Consume the "=" character
        closingDepth = closingDepth + 1
      end

      if self.curChar == "]" and closingDepth == depth then
        break
      end
    elseif self.curChar == "\0" then
      error("Unclosed long comment")
    end
    self:consume(1)
  end
end

function TokenizerMethods:consumeComment()
  self:consume(2) -- Consume the "--"
  if self.curChar == "[" then
    return self:consumeLongComment()
  end
  return self:consumeShortComment()
end

--// Token Consumer Handler //-- 
function TokenizerMethods:getNextToken()
  local curChar = self.curChar

  if self:isWhitespace(curChar) then
    self:consumeWhitespace()
    return
  elseif self:isComment() then
    self:consumeComment()
    return
  elseif self:isNumber(curChar) then
    return { TYPE = "Number", Value = tonumber(self:consumeNumber()) }
  elseif self:isIdentifierStart(curChar) then
    local identifier = self:consumeIdentifier()
    if TOKENIZER_LUA_OPERATORS_LOOKUP[identifier] then
      return { TYPE = "Operator", Value = identifier }
    elseif TOKENIZER_RESERVED_KEYWORDS_LOOKUP[identifier] then
      return { TYPE = "Keyword", Value = identifier }
    elseif TOKENIZER_LUA_CONSTANTS_LOOKUP[identifier] then
      return { TYPE = "Constant", Value = identifier }
    end
    return { TYPE = "Identifier", Value = identifier }
  elseif self:isString() then
    return { TYPE = "String", Value = self:consumeString() }
  elseif self:isVarArg() then
    self:consume(2)
    return { TYPE = "VarArg" }
  end

  local operator = self:consumeOperator()
  if operator then
    return { TYPE = "Operator", Value = operator }
  end
  return { TYPE = "Character", Value = curChar }
end

--// Tokenizer Main Method //--
function TokenizerMethods:tokenize()
  local tokens, tokenIndex = {}, 1
  while self.curChar do
    local token = self:getNextToken()
    if token then
      tokens[tokenIndex] = token
      tokenIndex         = tokenIndex + 1
    end
    self:consume(1)
  end
  return tokens
end

--* Tokenizer *--
local Tokenizer = {}
function Tokenizer.new(code)
  local TokenizerInstance = {}

  --// Local Variables //--
  local charStream = stringToChars(code)

  --// Initialization //--
  TokenizerInstance.code       = code
  TokenizerInstance.charStream = charStream
  TokenizerInstance.curCharPos = 1
  TokenizerInstance.curChar    = charStream[1]

  --// Method Binding //--
  insertValues(TokenizerInstance, TokenizerMethods)

  return TokenizerInstance
end

--[[
    ============================================================================
                                  (•_•)?
                              PARSER CONSTANTS
    ============================================================================

    Before diving into the parser's implementation, let's explore the essential
    constants and lookup tables that will guide the parsing process. These
    constants include Lua operators, unary operators, and stop keywords.
    By defining these constants upfront, we can streamline the parsing logic
    and ensure accurate identification and classification of tokens within the
    Lua code.
--]]

local PARSER_UNARY_OPERATOR_PRECEDENCE = 8
local PARSER_MULTIRET_NODE_TYPES = createLookupTable({ "FunctionCall", "VarArg" })
local PARSER_LVALUE_NODE_TYPES   = createLookupTable({ "Variable", "TableIndex" })
local PARSER_STOP_KEYWORDS       = createLookupTable({ "end", "else", "elseif", "until" })

--[[
  Precedence and associativity of Lua operators.
  The lower the number, the lower the priority of the operator.
  If the right precedence is higher than the left precedence, the operator is right-associative.
  Right-associative operators are evaluated from right to left.
--]]
local PARSER_OPERATOR_PRECEDENCE = {
  ["+"]   = {6, 6},  ["-"]  = {6, 6},
  ["*"]   = {7, 7},  ["/"]  = {7, 7}, ["%"] = {7, 7},
  ["^"]   = {10, 9}, [".."] = {5, 4},
  ["=="]  = {3, 3},  ["~="] = {3, 3},
  ["<"]   = {3, 3},  [">"]  = {3, 3}, ["<="] = {3, 3}, [">="] = {3, 3},
  ["and"] = {2, 2},  ["or"] = {1, 1}
}
local PARSER_LUA_UNARY_OPERATORS  = createLookupTable({ "-", "#", "not" })
local PARSER_LUA_BINARY_OPERATORS = createLookupTable({
  "+",  "-",   "*",  "/",
  "%",  "^",   "..", "==",
  "~=", "<",   ">",  "<=",
  ">=", "and", "or"
})

--[[
    ============================================================================
                                  ヽ/❀o ل͜ o\ﾉ
                                 THE PARSER!!!
    ============================================================================

    The parser is responsible for converting the list of tokens into an
    Abstract Syntax Tree (AST). The AST is a tree representation of the
    structure of the code. Each node in the tree represents a different
    part of the code. For example, a node could represent a function call,
    a binary operation, or a variable declaration. The parser will also
    perform some basic syntax checking to ensure the code is valid.
    One of the most interesting parts of the parser is the expression parser,
    which is responsible for placing operators and operands in the correct
    order based on their precedence and associativity.

    Here's an example of how the parser converts a simple Lua script into an
    Abstract Syntax Tree (AST):
    ```lua
    local x = 10 + 20
    ```
    The resulting AST would look like this:

--]]

--* ParserMethods *--
local ParserMethods = {}

--// Token Navigation //--
function ParserMethods:lookAhead(n)
  local updatedTokenIndex = self.currentTokenIndex + n
  local updatedToken      = self.tokens[updatedTokenIndex]
  return updatedToken
end

function ParserMethods:consume(n)
  local updatedTokenIndex = self.currentTokenIndex + n
  local updatedToken      = self.tokens[updatedTokenIndex]
  self.currentTokenIndex = updatedTokenIndex
  self.currentToken      = updatedToken
  return updatedToken
end

--// Scope Management //--
function ParserMethods:enterScope(isFunctionScope)
  local scope = {
    localVariables  = {},
    isFunctionScope = isFunctionScope
  }
  table.insert(self.scopeStack, scope)
  self.currentScope = scope
  return scope
end

function ParserMethods:exitScope()
  self.scopeStack[#self.scopeStack] = nil
  self.currentScope = self.scopeStack[#self.scopeStack]
end

--// In-Scope Variable Management //--
function ParserMethods:declareLocalVariable(variable)
  self.currentScope.localVariables[variable] = true
end

function ParserMethods:declareLocalVariables(variables)
  for _, variable in ipairs(variables) do
    self:declareLocalVariable(variable)
  end
end

function ParserMethods:getVariableType(variableName)
  local isUpvalue = false
  for scopeIndex = #self.scopeStack, 1, -1 do
    local scope = self.scopeStack[scopeIndex]
    if scope.localVariables[variableName] then
      local variableType = (isUpvalue and "Upvalue") or "Local"
      return variableType, scopeIndex
    elseif scope.isFunctionScope then
      isUpvalue = true
    end
  end
  return "Global"
end

--// Token Checkers //--
function ParserMethods:checkCharacter(character, token)
  token = token or self.currentToken
  return token
        and token.TYPE  == "Character"
        and token.Value == character
end

function ParserMethods:checkKeyword(keyword, token)
  token = token or self.currentToken
  return token
        and token.TYPE  == "Keyword"
        and token.Value == keyword
end

function ParserMethods:isComma(token)
  return token
        and token.TYPE == "Character"
        and token.Value == ","
end

function ParserMethods:isUnaryOperator(token)
  return token
        and token.TYPE == "Operator"
        and PARSER_LUA_UNARY_OPERATORS[token.Value]
end

function ParserMethods:isBinaryOperator(token)
  return token
        and token.TYPE == "Operator"
        and PARSER_LUA_BINARY_OPERATORS[token.Value]
end

--// AST Node Checkers //--
function ParserMethods:isValidAssignmentLvalue(node)
  return PARSER_LVALUE_NODE_TYPES[node.TYPE]
end
function ParserMethods:isMultiretNode(node)
  return PARSER_MULTIRET_NODE_TYPES[node.TYPE]
end

--// Token Expectation //--
function ParserMethods:expectTokenType(expectedType, skipConsume)
  local actualType = self.currentToken and self.currentToken.TYPE or "nil"
  assert(actualType == expectedType, string.format("Expected a %s, got: %s", expectedType, actualType))
  if not skipConsume then self:consume(1) end
  return self.currentToken
end

function ParserMethods:expectCharacter(character, skipConsume)
  local actualType = self.currentToken and self.currentToken.TYPE or "nil"
  assert(self.currentToken and self.currentToken.TYPE == "Character", "Expected a character, got: " .. actualType)
  assert(self.currentToken.Value == character, "Expected '" .. character .. "'")
  if not skipConsume then self:consume(1) end
  return self.currentToken
end

function ParserMethods:expectKeyword(keyword, skipConsume)
  local actualType = self.currentToken and self.currentToken.TYPE or "nil"
  assert(self.currentToken and self.currentToken.TYPE == "Keyword", "Expected a keyword, got: " .. actualType)
  assert(self.currentToken.Value == keyword, "Expected '" .. keyword .. "'")
  if not skipConsume then self:consume(1) end
  return self.currentToken
end

--// Auxiliary Functions //--
function ParserMethods:createNilNode()
  return { TYPE = "Constant", Value = "nil" }
end

function ParserMethods:adjustMultiretNodes(nodeList, expectedReturnAmount)
  local lastNode = nodeList[#nodeList]
  local extraReturns = expectedReturnAmount - #nodeList
  if lastNode and self:isMultiretNode(lastNode) then
    extraReturns = math.max(extraReturns + 1, -1)
    -- Adjust the return value amount
    lastNode.ReturnValueAmount = extraReturns
  else
    for _ = 1, extraReturns do
      table.insert(nodeList, self:createNilNode())
    end
  end
end

--// Parsers //--
function ParserMethods:consumeIdentifierList()
  local identifiers = {}
  while self.currentToken.TYPE == "Identifier" do
    table.insert(identifiers, self.currentToken.Value)
    if not self:isComma(self:lookAhead(1)) then break end
    self:consume(2) -- Consume identifier and ","
  end
  return identifiers
end

function ParserMethods:consumeParameterList()
  self:expectCharacter("(")
  local parameters, isVarArg = {}, false
  while not self:checkCharacter(")") do
    if self.currentToken.TYPE == "Identifier" then
      table.insert(parameters, self.currentToken.Value)
    elseif self.currentToken.TYPE == "VarArg" then
      isVarArg = true
      self:consume(1) -- Consume the "..."
      break
    end
    self:consume(1) -- Consume the last token of the parameter
    if not self:isComma(self.currentToken) then break end
    self:consume(1) -- Consume the comma
  end
  self:expectCharacter(")")
  return parameters, isVarArg
end

function ParserMethods:consumeTableIndex(currentExpression)
  self:consume(1) -- Consume the "." symbol
  local indexToken = { TYPE = "String",
    Value = self.currentToken.Value
  }
  return { TYPE = "TableIndex",
    Index = indexToken,
    Expression = currentExpression
  }
end

function ParserMethods:consumeBracketTableIndex(currentExpression)
  self:consume(1) -- Consume the "[" symbol
  local indexExpression = self:consumeExpression()
  self:consume(1) -- Consume the last token of the index expression
  self:expectCharacter("]", true)
  return { TYPE = "TableIndex",
    Index = indexExpression,
    Expression = currentExpression
  }
end

function ParserMethods:consumeTable()
  self:consume(1) -- Consume the "{" symbol
  local elements            = {}
  local implicitElements    = {}
  local explicitElements    = {}
  local internalImplicitKey = 1

  -- Loop until we find a "}" (end of the table)
  while not self:checkCharacter("}") do
    local key, value
    local isImplicitKey = false
    if self:checkCharacter("[") then
      -- [<expression>] = <expression>
      self:consume(1) -- Consume "["
      key = self:consumeExpression()
      self:consume(1) -- Consume the last token of the key
      self:expectCharacter("]")
      self:expectCharacter("=")
      value = self:consumeExpression()
    elseif self.currentToken.TYPE == "Identifier"
           and self:checkCharacter("=", self:lookAhead(1)) then
      -- <identifier> = <expression>
      key = { TYPE = "String",
        Value = self.currentToken.Value
      }
      self:consume(2) -- Consume key and "="
      value = self:consumeExpression()
    else
      -- <expression>
      key = { TYPE = "Number",
        Value = internalImplicitKey
      }
      internalImplicitKey = internalImplicitKey + 1
      isImplicitKey = true
      value = self:consumeExpression()
    end
    local element = { Key = key, Value = value, IsImplicitKey = isImplicitKey }
    local tableToInsert = (isImplicitKey and implicitElements) or explicitElements
    table.insert(tableToInsert, element)
    table.insert(elements, element)

    self:consume(1) -- Consume the last token of the expression

    -- Table elements can be separated by "," or ";"
    local shouldContinue = self:checkCharacter(",") or self:checkCharacter(";")
    if not shouldContinue then break end
    self:consume(1) -- Consume ","
  end
  local lastElement = elements[#elements]
  if lastElement and lastElement.IsImplicitKey then
    local lastElementValue = lastElement.Value.Value
    if self:isMultiretNode(lastElementValue) then
      lastElementValue.ReturnValueAmount = -1
    end
  end

  return { TYPE = "Table",
    Elements         = elements,
    ImplicitElements = implicitElements,
    ExplicitElements = explicitElements }
end

function ParserMethods:consumeFunctionCall(currentExpression)
  self:consume(1) -- Consume the "("
  local arguments = self:consumeExpressions()
  self:adjustMultiretNodes(arguments, -1)
  self:consume(1) -- Consume the last token of the expression
  return { TYPE = "FunctionCall",
    Expression = currentExpression,
    Arguments = arguments,
    ReturnValueAmount = 1,
    WithSelf = false
  }
end

function ParserMethods:consumeImplicitFunctionCall(lvalue)
  local currentTokenType = self.currentToken.TYPE

  -- <string>?
  if currentTokenType == "String" then
    local arguments = { self.currentToken }
    return {
      TYPE = "FunctionCall",
      Expression = lvalue,
      Arguments = arguments,
      ReturnValueAmount = 1,
      WithSelf = false
    }
  end

  -- <table>
  local arguments = { self:consumeTable() }
  return { TYPE = "FunctionCall",
    Expression = lvalue,
    Arguments = arguments,
    ReturnValueAmount = 1,
    WithSelf = false
  }
end

function ParserMethods:consumeMethodCall(currentExpression)
  local methodIdentifier = self:consume(1).Value -- Consume the ":" character, and get the method identifier
  self:consume(1) -- Consume the method identifier
  local methodIndexNode = { TYPE = "TableIndex",
    Index = { TYPE = "String",
      Value = methodIdentifier
    },
    Expression = currentExpression
  }
  local functionCallNode = self:consumeFunctionCall(methodIndexNode)
  functionCallNode.WithSelf = true -- Mark the function call as a method call
  return functionCallNode
end

function ParserMethods:consumeOptionalSemilcolon()
  local nextToken = self:lookAhead(1)
  if self:checkCharacter(";", nextToken) then
    self:consume(1)
  end
end

--// EXPRESSSION PARSERS //--
function ParserMethods:parsePrimaryExpression()
  if not self.currentToken then return end
  local tokenType = self.currentToken.TYPE
  local tokenValue = self.currentToken.Value

  if     tokenType == "Number"   then return { TYPE = "Number",   Value = tokenValue    }
  elseif tokenType == "String"   then return { TYPE = "String",   Value = tokenValue    }
  elseif tokenType == "Constant" then return { TYPE = "Constant", Value = tokenValue    }
  elseif tokenType == "VarArg"   then return { TYPE = "VarArg",   ReturnValueAmount = 1 }
  elseif tokenType == "Identifier" then
    local variableType = self:getVariableType(tokenValue)
    local variableNode = { TYPE = "Variable",
      Value = tokenValue,
      VariableType = variableType
    }
    return variableNode
  elseif tokenType == "Character" then
    if tokenValue == "(" then -- Parenthesized expression
      self:consume(1) -- Consume the parenthesis
      local expression = self:consumeExpression()
      self:consume(1) -- Consume the last token of the expression
      return expression
    elseif tokenValue == "{" then -- Table constructor
      return self:consumeTable()
    end
  elseif tokenType == "Keyword" then
    if tokenValue == "function" then
      self:consume(1) -- Consume the "function" token
      local parameters, isVarArg = self:consumeParameterList()
      local codeblock = self:parseCodeBlock(true, parameters)
      self:expectKeyword("end", true)
      return { TYPE = "Function",
        CodeBlock = codeblock,
        Parameters = parameters,
        IsVarArg = isVarArg
      }
    end
  end
  return nil
end

function ParserMethods:parseSuffixExpression(primaryExpression)
  local nextToken = self:lookAhead(1)
  local nextTokenValue = nextToken and nextToken.Value
  if nextTokenValue == "(" then -- Function call
    self:consume(1)
    -- <expression> \( <args> \)
    return self:consumeFunctionCall(primaryExpression)
  elseif nextTokenValue == "." then -- Table access
    self:consume(1)
    -- <expression> \. <identifier>
    return self:consumeTableIndex(primaryExpression)
  elseif nextTokenValue == ":" then -- Method call
    self:consume(1)
    -- <expression> \: <identifier> \( <args> \)
    return self:consumeMethodCall(primaryExpression)
  elseif nextTokenValue == "[" then -- Table index
    self:consume(1)
    -- <expression> \[ <expression> \]
    return self:consumeBracketTableIndex(primaryExpression)
  elseif nextToken then
    -- In some edge cases, a user may call a function using only string,
    -- example: `print "Hello, World!"`. This is a valid Lua syntax.
    -- Let's handle both strings and tables here for that case.
    local nextTokenType = nextToken.TYPE
    if nextTokenType == "String" or (nextTokenValue == "{" and nextTokenType == "Character") then
      self:consume(1)
      return self:consumeImplicitFunctionCall(primaryExpression)
    end
  end
  return nil
end

function ParserMethods:parsePrefixExpression()
  local primaryExpression = self:parsePrimaryExpression() -- <primary>
  if not primaryExpression then return end

  -- <suffix>*
  while (true) do
    local newExpression = self:parseSuffixExpression(primaryExpression)
    if not newExpression then break end
    primaryExpression = newExpression
  end

  return primaryExpression
end

function ParserMethods:parseUnaryOperator()
  local unaryOperator = self.currentToken
  -- <unary> ::= <unary operator> <unary> | <primary>
  if not self:isUnaryOperator(self.currentToken) then
    return self:parsePrefixExpression()
  end

  -- <unary operator> <unary>
  self:consume(1) -- Consume the operator
  local expression = self:parseBinaryExpression(PARSER_UNARY_OPERATOR_PRECEDENCE)
  return { TYPE = "UnaryOperator",
    Operator = unaryOperator.Value,
    Operand = expression
  }
end

function ParserMethods:parseBinaryExpression(minPrecedence)
  -- <binary> ::= <unary> <binary operator> <binary> | <unary>
  minPrecedence = minPrecedence or 0
  local expression = self:parseUnaryOperator() -- <unary>
  if not expression then return end

  -- [<binary operator> <binary>]
  while true do
    local operatorToken = self:lookAhead(1)
    local precedence = operatorToken and PARSER_OPERATOR_PRECEDENCE[operatorToken.Value]
    if not self:isBinaryOperator(operatorToken) or precedence[1] <= minPrecedence then
      break
    end

    -- The <binary operator> <binary> part itself
    local nextToken = self:consume(2) -- Advance to and consume the operator
    if not nextToken then error("Unexpected end") end

    local right = self:parseBinaryExpression(precedence[2])
    if not right then error("Unexpected end") end

    expression = { TYPE = "BinaryOperator",
      Operator = operatorToken.Value,
      Left = expression, Right = right
    }
  end
  return expression
end

function ParserMethods:consumeExpression(returnRawNode)
  local expression = self:parseBinaryExpression(0)
  if not expression then
    -- Backtrack to the last token
    self:consume(-1)
    return
  end
  if returnRawNode then return expression end
  return { TYPE = "Expression",
    Value = expression
  }
end

function ParserMethods:consumeExpressions()
  local expressions = { self:consumeExpression(true) }
  if #expressions == 0 then return {} end

  local nextToken = self:lookAhead(1)
  while self:isComma(nextToken) do
    self:consume(2) -- Consume the last token of the last expression and ","
    local expression = self:consumeExpression(true)
    table.insert(expressions, expression)
    nextToken = self:lookAhead(1)
  end

  return expressions
end

--// STATEMENT PARSERS //--
function ParserMethods:parseLocal()
  self:consume(1) -- Consume the "local" token
  if self:checkKeyword("function") then
    self:consume(1) -- Consume the "function" token
    local name = self.currentToken.Value
    self:consume(1) -- Consume the last token of the identifier)
    local parameters, isVarArg = self:consumeParameterList()
    self:declareLocalVariable(name)
    local codeblock = self:parseCodeBlock(true, parameters)
    self:expectKeyword("end", true)
    return { TYPE = "LocalFunctionDeclaration",
      Name = name,
      CodeBlock = codeblock,
      Parameters = parameters,
      IsVarArg = isVarArg
    }
  end
  local variables = self:consumeIdentifierList()
  if self:checkCharacter("=", self:lookAhead(1)) then
    self:consume(1) -- Consume the last token of the last identifier
    self:expectCharacter("=")
    local expressions = self:consumeExpressions()
    self:adjustMultiretNodes(expressions, #variables)
    self:declareLocalVariables(variables)
    return { TYPE = "LocalDeclaration",
      Variables = variables,
      Expressions = expressions
    }
  end
  self:declareLocalVariables(variables)
  return { TYPE = "LocalDeclaration",
    Variables = variables,
    Expressions = {}
  }
end

function ParserMethods:parseWhile()
  self:consume(1) -- Consume the "while" token
  local condition = self:consumeExpression()
  self:consume(1) -- Consume the last token of the condition
  self:expectKeyword("do")
  local codeblock = self:parseCodeBlock()
  self:expectKeyword("end", true)
  return { TYPE = "WhileLoop",
    Condition = condition,
    CodeBlock = codeblock
  }
end

function ParserMethods:parseRepeat()
  self:consume(1) -- Consume the "repeat" token
  local codeblock = self:parseCodeBlock()
  self:expectKeyword("until")
  local condition = self:consumeExpression()
  return { TYPE = "RepeatLoop",
    CodeBlock = codeblock,
    Condition = condition
  }
end

function ParserMethods:parseDo()
  self:consume(1) -- Consume the "do" token
  local codeblock = self:parseCodeBlock()
  self:expectKeyword("end", true)
  return { TYPE = "DoBlock",
    CodeBlock = codeblock
  }
end

function ParserMethods:parseReturn()
  self:consume(1) -- Consume the "return" token
  local expressions = self:consumeExpressions()
  self:adjustMultiretNodes(expressions, -1)
  return { TYPE = "ReturnStatement",
    Expressions = expressions
  }
end

function ParserMethods:parseBreak()
  return { TYPE = "BreakStatement" }
end

function ParserMethods:parseIf()
  self:consume(1) -- Consume the "if" token
  local ifCondition = self:consumeExpression()
  self:consume(1) -- Consume the last token of the if condition
  self:expectKeyword("then")
  local ifCodeBlock = self:parseCodeBlock()
  local branches = { TYPE = "IfBranchList",
    { TYPE = "IfBranch",
      Condition = ifCondition,
      CodeBlock = ifCodeBlock
    }
  }
  while self:checkKeyword("elseif") do
    self:consume(1) -- Consume the "elseif" token
    local elseifCondition = self:consumeExpression()
    self:consume(1) -- Consume the last token of the elseif condition
    self:expectKeyword("then")
    local elseifCodeBlock = self:parseCodeBlock()
    local ifBranch = { TYPE = "IfBranch",
      Condition = elseifCondition,
      CodeBlock = elseifCodeBlock
    }
    table.insert(branches, ifBranch)
  end
  local elseCodeBlock
  if self:checkKeyword("else") then
    self:consume(1) -- Consume the "else" token
    elseCodeBlock = self:parseCodeBlock()
  end
  self:expectKeyword("end", true)
  return { TYPE = "IfStatement",
    Branches = branches,
    ElseCodeBlock = elseCodeBlock
  }
end

function ParserMethods:parseFor()
  self:consume(1) -- Consume the "for" token
  local variableName = self:expectTokenType("Identifier", true).Value
  self:consume(1) -- Consume the variable name
  if self:checkCharacter(",") or self:checkKeyword("in") then
    local iteratorVariables = { variableName }
    while self:checkCharacter(",") do
      self:consume(1) -- Consume the comma
      local newVariableName = self:expectTokenType("Identifier", true).Value
      table.insert(iteratorVariables, newVariableName)
      self:consume(1) -- Consume the variable name
    end
    self:expectKeyword("in")
    local expressions = self:consumeExpressions()
    self:adjustMultiretNodes(expressions, 3)
    self:consume(1) -- Consume the last token of the expressions
    self:expectKeyword("do")
    local codeblock = self:parseCodeBlock(false, iteratorVariables)
    self:expectKeyword("end", true)
    return { TYPE = "GenericForLoop",
      IteratorVariables = iteratorVariables,
      Expressions = expressions,
      CodeBlock = codeblock
    }
  end
  self:expectCharacter("=")
  local expressions = self:consumeExpressions()
  self:consume(1) -- Consume the last token of the expressions
  self:expectKeyword("do")
  local codeblock = self:parseCodeBlock(false, { variableName })
  self:expectKeyword("end", true)
  return { TYPE = "NumericForLoop",
    VariableName = variableName,
    Expressions = expressions,
    CodeBlock = codeblock
  }
end

function ParserMethods:parseFunction()
  -- fuction <variable>[.<field>]:<method>(...)
  --   <codeblock>
  -- end

  self:consume(1) -- Consume the "function" token
  local variableName = self:expectTokenType("Identifier", true).Value
  local variableType = self:getVariableType(variableName)
  local expression = { TYPE = "Variable", Value = variableName, VariableType = variableType }
  local fields, isMethod = { }, false
  while self:consume(1) do
    if self:checkCharacter(".") then
      self:consume(1) -- Consume the "."
      local fieldName = self:expectTokenType("Identifier", true).Value
      table.insert(fields, fieldName)
    elseif self:checkCharacter(":") then
      self:consume(1) -- Consume the ":"
      local methodName = self:expectTokenType("Identifier", true).Value
      table.insert(fields, methodName)
      isMethod = true
      self:consume(1) -- Consume the method name
      break
    else break end
  end
  local parameters, isVarArg = self:consumeParameterList()
  if isMethod then
    table.insert(parameters, 1, "self")
  end
  local codeblock = self:parseCodeBlock(true, parameters)
  self:expectKeyword("end", true)
  return { TYPE = "FunctionDeclaration",
    Expression = expression,
    Fields = fields,
    IsMethod = isMethod,
    CodeBlock = codeblock,
    Parameters = parameters,
    IsVarArg = isVarArg
  }
end

function ParserMethods:parseAssignment(lvalue)
  local lvalues = { lvalue }
  self:consume(1) -- Consume the last token of the lvalue
  while self:isComma(self.currentToken) do
    self:consume(1) -- Consume the comma
    local nextLValue = self:parsePrefixExpression()
    if not nextLValue then error("Expected an lvalue") end
    if not self:isValidAssignmentLvalue(nextLValue) then
      error("Expected a variable or index, got: " .. nextLValue.TYPE)
    end
    table.insert(lvalues, nextLValue)
    self:consume(1) -- Consume the last token of the lvalue
  end
  self:expectCharacter("=")
  local expressions = self:consumeExpressions()
  self:adjustMultiretNodes(expressions, #lvalues)
  return { TYPE = "VariableAssignment",
    LValues = lvalues,
    Expressions = expressions
  }
end

function ParserMethods:parseFunctionCallOrVariableAssignment()
  local lvalue = self:parsePrefixExpression()
  local lvalueType = tostring(lvalue and lvalue.TYPE)
  if lvalue then
    if self:isValidAssignmentLvalue(lvalue) then
      return self:parseAssignment(lvalue)
    elseif lvalueType == "FunctionCall" then
      lvalue.ReturnValueAmount = 0
      return lvalue
    end
    error("Unexpected lvalue type: " .. lvalueType)
  end
  error("Expected an lvalue, got: " .. lvalueType)
end

--// CODE BLOCK PARSERS //--
function ParserMethods:getNextNode()
  local currentTokenValue = self.currentToken.Value
  local currentTokenType  = self.currentToken.TYPE
  local node

  if currentTokenType == "Keyword" then
    if PARSER_STOP_KEYWORDS[currentTokenValue] then return
    elseif currentTokenValue == "local"        then node = self:parseLocal()
    elseif currentTokenValue == "while"        then node = self:parseWhile()
    elseif currentTokenValue == "repeat"       then node = self:parseRepeat()
    elseif currentTokenValue == "do"           then node = self:parseDo()
    elseif currentTokenValue == "return"       then node = self:parseReturn()
    elseif currentTokenValue == "break"        then node = self:parseBreak()
    elseif currentTokenValue == "if"           then node = self:parseIf()
    elseif currentTokenValue == "for"          then node = self:parseFor()
    elseif currentTokenValue == "function"     then node = self:parseFunction()
    else error("Unsupported keyword: " .. currentTokenValue) end
  else
    node = self:parseFunctionCallOrVariableAssignment()
  end
  self:consumeOptionalSemilcolon()

  return node
end

function ParserMethods:parseCodeBlock(isFunctionScope, codeBlockVariables)
  self:enterScope(isFunctionScope)
  if codeBlockVariables then
    self:declareLocalVariables(codeBlockVariables)
  end

  local nodeList = { TYPE = "Group" }
  while self.currentToken do
    local node = self:getNextNode()
    if not node then break end
    table.insert(nodeList, node)
    self:consume(1)
  end

  self:exitScope()
  return nodeList
end

--// MAIN //--
function ParserMethods:parse()
  local ast = self:parseCodeBlock()
  ast.TYPE = "AST"

  return ast
end

--* Parser *--
local Parser = {}
function Parser.new(tokens)
  local ParserInstance = {}

  --// Initialization //--
  ParserInstance.tokens = tokens
  ParserInstance.currentTokenIndex = 1
  ParserInstance.currentToken = tokens[1]
  ParserInstance.scopeStack = {}
  ParserInstance.currentScope = nil

  --// Method Binding //--
  insertValues(ParserInstance, ParserMethods)

  return ParserInstance
end

--[[
    ============================================================================
                                     (•_•)?
                              CODE GENERATOR CONSTANTS
    ============================================================================

    Before diving into the compiler's implementation, let's explore the essential
    constants and lookup tables that will guide the compilation process. These
    constants include Lua operators, unary operators, and stop keywords.
    By defining these constants upfront, we can streamline the compilation logic
    and ensure accurate identification and classification of tokens within the
    Lua code.
--]]
local unpack = (unpack or table.unpack)

local COMPILER_SETLIST_MAX = 50
local COMPILER_SIMPLE_ARICHMETIC_OPERATOR_LOOKUP = {
  ["+"] = "ADD", ["-"] = "SUB",
  ["*"] = "MUL", ["/"] = "DIV",
  ["%"] = "MOD", ["^"] = "POW"
}
local COMPILER_UNARY_OPERATOR_LOOKUP = { ["-"] = "UNM", ["#"] = "LEN", ["not"] = "NOT" }
local COMPILER_COMPARISON_INSTRUCTION_LOOKUP = {
  ["=="] = {"EQ", 1}, ["~="] = {"EQ", 0},
  ["<"]  = {"LT", 1}, [">"]  = {"LT", 1},
  ["<="] = {"LE", 1}, [">="] = {"LE", 1}
}
local COMPILER_COMPARISON_OPERATOR_LOOKUP = createLookupTable({"==", "~=", "<", ">", "<=", ">="})
local COMPILER_CONTROL_FLOW_OPERATOR_LOOKUP = createLookupTable({"and", "or"})

--[[
    ============================================================================
                                 (づ｡◕‿‿◕｡)づ
                            THE CODE GENERATOR!!!
    ============================================================================

    Possibly the most complex part of the compiler, the Code Generator is
    responsible for converting the AST into Lua instructions, which are
    similar to assembly instructions, but they are much higher level,
    because they're being executed in the Lua VM (Virtual Machine),
    not on a physical CPU. The Code Generator will also be responsible
    for generating the function prototypes, which are used to store
    information about the function, such as the number of arguments,
    the number of local variables, and the number of upvalues.

    Here's an example of how the Code Generator converts a simple AST
    into Lua instructions:
    ```lua
 
    ```
    The resulting proto would look like this:

--]]

--* CodeGeneratorMethods *--
local CodeGeneratorMethods = {}

--// Prototype Management //--
function CodeGeneratorMethods:setProto(proto)
  self.currentProto   = proto
  self.takenRegisters = proto.takenRegisters
  self.code           = proto.code
  self.constants      = proto.constants
  self.constantLookup = proto.constantLookup
  self.upvalues       = proto.upvalues
  self.upvalueLookup  = proto.upvalueLookup
  self.protos         = proto.protos
end

function CodeGeneratorMethods:newProto()
  self.currentProto = {
    takenRegisters = {},
    code           = {},
    constants      = {},
    constantLookup = {},
    upvalues       = {},
    upvalueLookup  = {},
    protos         = {},
    numParams      = 0,
    isVarArg       = false,
    functionName   = "@tlc",
  }
  self:setProto(self.currentProto)
  return self.currentProto
end

--// Register Management //--
function CodeGeneratorMethods:allocateRegister()
  local newRegister = (self.takenRegisters[0] and #self.takenRegisters + 1) or 0
  if newRegister > 255 then
    error("Out of registers")
  end
  self.takenRegisters[newRegister] = true
  return newRegister
end

function CodeGeneratorMethods:deallocateRegister(register)
  self.takenRegisters[register] = nil
end

function CodeGeneratorMethods:deallocateRegisters(registers)
  for _, register in ipairs(registers) do
    self:deallocateRegister(register)
  end
end

--// Variable Management //--
function CodeGeneratorMethods:getVariableType(variableName)
  local scope = self.currentScope
  local isUpvalue = false
  while scope do
    if scope.locals[variableName] then
      return (isUpvalue and "Upvalue") or "Local"
    elseif scope.isFunctionScope then
      isUpvalue = true
    end
    scope = scope.previousScope
  end
  return "Global"
end

function CodeGeneratorMethods:findVariableRegister(localName)
  local scope = self.currentScope
  while scope do
    local variableRegister = scope.locals[localName]
    if variableRegister then
      return variableRegister
    elseif scope.isFunctionScope then
      break
    end
    local previousScope = scope.previousScope
    scope = previousScope
  end
  error("Could not find variable: " .. localName)
end

function CodeGeneratorMethods:registerVariable(localName, register)
  self.locals[localName] = register
end

function CodeGeneratorMethods:unregisterVariable(variableName)
  local locals = self.locals
  local variableRegister = locals[variableName]
  if not variableRegister then
    error("Attempt to unregister undeclared variable: " .. variableName)
  end

  -- Unregister it
  self:deallocateRegister(variableRegister)
  locals[variableName] = nil
end

function CodeGeneratorMethods:unregisterVariables(variables)
  for _, variableName in ipairs(variables) do
    self:unregisterVariable(variableName)
  end
end

--// Scope Management //--
function CodeGeneratorMethods:enterScope(isFunctionScope)
  local newScope = {
    locals = {},
    isFunctionScope = isFunctionScope,
    previousScope = self.scopes[#self.scopes]
  }
  self.locals = newScope.locals
  table.insert(self.scopes, newScope)
  self.currentScope = newScope
  return newScope
end

function CodeGeneratorMethods:exitScope()
  table.remove(self.scopes)
  for variableName in pairs(self.currentScope.locals) do
    self:unregisterVariable(variableName)
  end

  if #self.scopes > 0 then
    self.currentScope = self.scopes[#self.scopes]
    self.locals = self.currentScope.locals
  end
end

--// Utility Functions //--
function CodeGeneratorMethods:isMultiretNode(node)
  if not node then return false end
  return PARSER_MULTIRET_NODE_TYPES[node.TYPE]
end

function CodeGeneratorMethods:updateJumpInstruction(instructionIndex)
  local currentInstructionIndex = #self.code
  local jumpDistance = currentInstructionIndex - instructionIndex
  local instruction = self.code[instructionIndex]
  instruction[3] = jumpDistance
end

function CodeGeneratorMethods:updateJumpInstructions(list)
  for _, instructionIndex in ipairs(list) do
    self:updateJumpInstruction(instructionIndex)
  end
end

function CodeGeneratorMethods:findOrCreateConstant(value)
  if self.constantLookup[value] then
    return self.constantLookup[value]
  end
  table.insert(self.constants, value)
  local constantIndex = -(#self.constants)
  self.constantLookup[value] = constantIndex
  return constantIndex
end

function CodeGeneratorMethods:findOrCreateUpvalue(value)
  if self.upvalueLookup[value] then
    return self.upvalueLookup[value]
  end
  table.insert(self.upvalues, value)
  local upvalueIndex = #self.upvalues - 1
  self.upvalueLookup[value] = upvalueIndex
  return upvalueIndex
end

function CodeGeneratorMethods:addInstruction(opname, a, b, c)
  local instruction = { opname, a, b, c }
  table.insert(self.code, instruction)
  return #self.code
end

--// Expression Compilation //--
function CodeGeneratorMethods:compileNumberNode(node, expressionRegister)
  local constantIndex = self:findOrCreateConstant(node.Value)
  -- OP_LOADK [A, Bx]    R(A) := Kst(Bx)
  self:addInstruction("LOADK", expressionRegister, constantIndex)
  return expressionRegister
end

function CodeGeneratorMethods:compileStringNode(node, expressionRegister)
  local constantIndex = self:findOrCreateConstant(node.Value)
  -- OP_LOADK [A, Bx]    R(A) := Kst(Bx)
  self:addInstruction("LOADK", expressionRegister, constantIndex)
  return expressionRegister
end

function CodeGeneratorMethods:compileFunctionNode(node, expressionRegister)
  self:processFunction(node, expressionRegister)
  return expressionRegister
end

function CodeGeneratorMethods:compileFunctionCallNode(node, expressionRegister)
  -- Special register allocation case for function calls as they can be used both
  -- as expressions and statements
  expressionRegister = expressionRegister or self:allocateRegister()

  local selfArgumentRegister
  -- Check if it's not a method call
  if not node.WithSelf then
    self:processExpressionNode(node.Expression, expressionRegister)
  else
    -- Prepare a register for the self argument to be used
    -- later in the method call instruction
    local nodeExpressionIndex      = node.Expression.Index
    local nodeExpressionExpression = node.Expression.Expression
    self:processExpressionNode(nodeExpressionExpression, expressionRegister)
    selfArgumentRegister = self:allocateRegister()
    local nodeIndexRegister = self:processExpressionNode(nodeExpressionIndex)
    -- OP_SELF [A, B, C]    R(A+1) := R(B) R(A) := R(B)[RK(C)]
    self:addInstruction("SELF", expressionRegister, expressionRegister, nodeIndexRegister)
    self:deallocateRegister(nodeIndexRegister)
  end
  local argumentRegisters = self:processExpressionNodes(node.Arguments)
  if selfArgumentRegister then
    -- Add an extra register for the self argument
    table.insert(argumentRegisters, 1, selfArgumentRegister)
  end
  local returnAmount   = math.max(0, node.ReturnValueAmount + 1)
  local argumentAmount = #argumentRegisters + 1
  if self:isMultiretNode(node.Arguments[#node.Arguments]) then
    argumentAmount = 0
  end
  -- OP_CALL [A, B, C]    R(A), ... ,R(A+C-2) := R(A)(R(A+1), ... ,R(A+B-1))
  self:addInstruction("CALL", expressionRegister, argumentAmount, returnAmount)
  self:deallocateRegisters(argumentRegisters)
  local returnRegisters = { expressionRegister }
  for _ = expressionRegister + 1, expressionRegister + node.ReturnValueAmount - 1 do
    table.insert(returnRegisters, self:allocateRegister())
  end

  return unpack(returnRegisters)
end

function CodeGeneratorMethods:compileConstantNode(node, expressionRegister)
  local nodeValue = node.Value
  if nodeValue ~= "nil" then
    local secondValue = (nodeValue == "true" and 1) or 0
    -- OP_LOADBOOL [A, B, C]    R(A) := (Bool)B if (C) pc++
    self:addInstruction("LOADBOOL", expressionRegister, secondValue, 0)
  else
    -- OP_LOADNIL [A, B]    R(A) := ... := R(B) := nil
    self:addInstruction("LOADNIL", expressionRegister, expressionRegister)
  end
  return expressionRegister
end

function CodeGeneratorMethods:compileVarArgNode(node, expressionRegister)
  local returnAmount = node.ReturnValueAmount + 1
  if returnAmount <= 0 then returnAmount = 0 end
  -- OP_VARARG [A, B]    R(A), R(A+1), ..., R(A+B-1) = vararg
  self:addInstruction("VARARG", expressionRegister, returnAmount)
  local returnRegisters = { expressionRegister }
  for _ = expressionRegister + 1, expressionRegister + node.ReturnValueAmount - 1 do
    table.insert(returnRegisters, self:allocateRegister())
  end
  return unpack(returnRegisters)
end

function CodeGeneratorMethods:compileTableIndexNode(node, expressionRegister)
  self:processExpressionNode(node.Expression, expressionRegister)
  local indexRegister = self:processExpressionNode(node.Index)
  -- OP_GETTABLE [A, B, C]    R(A) := R(B)[RK(C)]
  self:addInstruction("GETTABLE", expressionRegister, expressionRegister, indexRegister)
  self:deallocateRegister(indexRegister)
  return expressionRegister
end

function CodeGeneratorMethods:compileTableNode(node, expressionRegister)
  local implicitElements = node.ImplicitElements
  local explicitElements = node.ExplicitElements
  local sizeB = math.min(#implicitElements, 255)
  local sizeC = math.min(#explicitElements, 255)
  -- OP_NEWTABLE [A, B, C]    R(A) := {} (size = B,C)
  self:addInstruction("NEWTABLE", expressionRegister, sizeB, sizeC)
  for _, element in ipairs(explicitElements) do
    local valueRegister = self:processExpressionNode(element.Value)
    local keyRegister   = self:processExpressionNode(element.Key)
    self:deallocateRegisters({ keyRegister, valueRegister })

    -- OP_SETTABLE [A, B, C]    R(A)[RK(B)] := RK(C)
    self:addInstruction("SETTABLE", expressionRegister, keyRegister, valueRegister)
  end

  local pages = math.ceil(#implicitElements / COMPILER_SETLIST_MAX)
  for page = 1, pages do
    local startIndex = (page - 1) * COMPILER_SETLIST_MAX + 1
    local endIndex   = math.min(page * COMPILER_SETLIST_MAX, #implicitElements)
    local currentPageRegisters = {}
    for elementIndex = startIndex, endIndex do
      local element       = implicitElements[elementIndex]
      local elementValue  = element.Value
      local valueRegister = self:processExpressionNode(elementValue)

      table.insert(currentPageRegisters, valueRegister)
    end
    local lastElement               = implicitElements[endIndex]
    local lastElementValue          = lastElement.Value.Value
    local currentPageRegisterAmount = #currentPageRegisters
    if page == pages and self:isMultiretNode(lastElementValue) then
      -- B = 0: Doesn't have a fixed amount of keys (multiret)
      currentPageRegisterAmount = 0
    end
    -- OP_SETLIST [A, B, C]    R(A)[(C-1)*FPF+i] := R(A+i), 1 <= i <= B
    self:addInstruction("SETLIST", expressionRegister, currentPageRegisterAmount, page)
    self:deallocateRegisters(currentPageRegisters)
  end

  return expressionRegister
end

function CodeGeneratorMethods:compileVariableNode(node, expressionRegister)
  local variableType = node.VariableType
  if variableType == "Global" then
    -- OP_GETGLOBAL [A, Bx]    R(A) := Gbl[Kst(Bx)]
    self:addInstruction("GETGLOBAL", expressionRegister, self:findOrCreateConstant(node.Value))
  elseif variableType == "Local" then
    local variableRegister = self:findVariableRegister(node.Value)
    -- OP_MOVE [A, B]    R(A) := R(B)
    self:addInstruction("MOVE", expressionRegister, variableRegister)
  elseif variableType == "Upvalue" then
    -- OP_GETUPVAL [A, B]    R(A) := UpValue[B]
    self:addInstruction("GETUPVAL", expressionRegister, self:findOrCreateUpvalue(node.Value))
  end
  return expressionRegister
end

function CodeGeneratorMethods:compileBinaryOperatorNode(node, expressionRegister)
  local nodeOperator = node.Operator
  if COMPILER_SIMPLE_ARICHMETIC_OPERATOR_LOOKUP[nodeOperator] then
    local opcode = COMPILER_SIMPLE_ARICHMETIC_OPERATOR_LOOKUP[nodeOperator]
    local leftExpressionRegister = self:processExpressionNode(node.Left)
    local rightExpressionRegister = self:processExpressionNode(node.Right)
    self:addInstruction(opcode, expressionRegister, leftExpressionRegister, rightExpressionRegister)
    self:deallocateRegisters({ leftExpressionRegister, rightExpressionRegister })
  elseif COMPILER_CONTROL_FLOW_OPERATOR_LOOKUP[nodeOperator] then
    local leftExpressionRegister = self:processExpressionNode(node.Left, expressionRegister)
    local isConditionTrue = (nodeOperator == "and" and 0) or 1
    -- OP_TEST [A, C]    if not (R(A) <=> C) then pc++
    self:addInstruction("TEST", leftExpressionRegister, 0, isConditionTrue)
    -- OP_JMP [A, sBx]    pc+=sBx
    local jumpInstructionIndex = self:addInstruction("JMP", 0, 0)
    self:processExpressionNode(node.Right, expressionRegister)
    self:updateJumpInstruction(jumpInstructionIndex)
  elseif COMPILER_COMPARISON_OPERATOR_LOOKUP[nodeOperator] then
    local leftExpressionRegister = self:processExpressionNode(node.Left)
    local rightExpressionRegister = self:processExpressionNode(node.Right)
    local instruction, flag = unpack(COMPILER_COMPARISON_INSTRUCTION_LOOKUP[nodeOperator])
    if nodeOperator == ">" or nodeOperator == ">=" then
      leftExpressionRegister, rightExpressionRegister = rightExpressionRegister, leftExpressionRegister
    end
    self:addInstruction(instruction, flag, leftExpressionRegister, rightExpressionRegister)
    -- OP_JMP [A, sBx]    pc+=sBx
    self:addInstruction("JMP", 0, 1)
    -- OP_LOADBOOL [A, B, C]    R(A) := (Bool)B if (C) pc++
    self:addInstruction("LOADBOOL", expressionRegister, 0, 1)
    self:addInstruction("LOADBOOL", expressionRegister, 1, 0)
    self:deallocateRegisters({ leftExpressionRegister, rightExpressionRegister })
  elseif nodeOperator == ".." then
    local leftExpressionRegister = self:processExpressionNode(node.Left)
    local rightExpressionRegister = self:processExpressionNode(node.Right)
    if (rightExpressionRegister - leftExpressionRegister) ~= 1 then
      error("Concatenation requires consecutive registers")
    end
    -- OP_CONCAT [A, B, C]    R(A) := R(B).. ... ..R(C)
    self:addInstruction("CONCAT", expressionRegister, leftExpressionRegister, rightExpressionRegister)
    self:deallocateRegisters({ leftExpressionRegister, rightExpressionRegister })
  end
  return expressionRegister
end

function CodeGeneratorMethods:compileUnaryOperatorNode(node, expressionRegister)
  local nodeOperator      = node.Operator
  local operatorOpcode    = COMPILER_UNARY_OPERATOR_LOOKUP[nodeOperator]
  local operandExpression = self:processExpressionNode(node.Operand)
  self:addInstruction(operatorOpcode, expressionRegister, operandExpression)
  self:deallocateRegister(operandExpression)
  return expressionRegister
end

--// Statement Compilation //--
function CodeGeneratorMethods:compileBreakStatementNode()
  -- OP_JMP [A, sBx]    pc+=sBx
  local jumpInstructionIndex = self:addInstruction("JMP", 0, 0)
  table.insert(self.breakInstructions, jumpInstructionIndex)
end

function CodeGeneratorMethods:compileLocalFunctionDeclarationNode(node)
  local name          = node.Name
  local localRegister = self:allocateRegister()
  self:registerVariable(name, localRegister)
  self:processFunction(node, localRegister, name)
end
function CodeGeneratorMethods:compileFunctionDeclarationNode(node)
  local expression = node.Expression
  local fields     = node.Fields
  if #fields > 0 then
    local closureRegister = self:allocateRegister()
    local lastField = fields[#fields]
    self:processFunction(node, closureRegister, lastField)
    local expressionRegister = self:processExpressionNode(expression)
    for index, field in ipairs(fields) do
      local fieldRegister = self:allocateRegister()
      -- OP_LOADK [A, Bx]    R(A) := Kst(Bx)
      self:addInstruction("LOADK", fieldRegister, self:findOrCreateConstant(field))
      if index == #fields then
        -- OP_SETTABLE [A, B, C]    R(A)[RK(B)] := RK(C)
        self:addInstruction("SETTABLE", expressionRegister, fieldRegister, closureRegister)
      else
        -- OP_GETTABLE [A, B, C]    R(A) := R(B)[RK(C)]
        self:addInstruction("GETTABLE", expressionRegister, expressionRegister, fieldRegister)
      end
      self:deallocateRegister(fieldRegister)
    end
    self:deallocateRegisters({ closureRegister, expressionRegister })
    return
  end
  local variableName = expression.Value
  if expression.VariableType == "Local" then
    local localRegister = self:findVariableRegister(variableName)
    self:processFunction(node, localRegister, variableName)
  elseif expression.VariableType == "Upvalue" then
    local closureRegister = self:allocateRegister()
    self:processFunction(node, closureRegister, variableName)
    -- OP_SETUPVAL [A, B]    UpValue[B] := R(A)
    self:addInstruction("SETUPVAL", closureRegister, self:findOrCreateUpvalue(variableName))
    self:deallocateRegister(closureRegister)
  elseif expression.VariableType == "Global" then
    local globalRegister = self:allocateRegister()
    self:processFunction(node, globalRegister, variableName)
    -- OP_SETGLOBAL [A, Bx]    Gbl[Kst(Bx)] := R(A)
    self:addInstruction("SETGLOBAL", globalRegister, self:findOrCreateConstant(variableName))
    self:deallocateRegister(globalRegister)
  end
end

function CodeGeneratorMethods:compileLocalDeclarationNode(node)
  local variableExpressionRegisters = {}
  for index, expression in ipairs(node.Expressions) do
    local expressionRegisters = { self:processExpressionNode(expression) }
    for index2, expressionRegister in ipairs(expressionRegisters) do
      table.insert(variableExpressionRegisters, expressionRegister)
      if not node.Variables[index + index2 - 1] then
        -- If this expression doesn't have a corresponding variable, deallocate it
        self:deallocateRegister(expressionRegister)
      end
    end
  end
  for index, localName in ipairs(node.Variables) do
    local expressionRegister = variableExpressionRegisters[index]
    if not expressionRegister then
      expressionRegister = self:allocateRegister()
      -- Load nil into the register
      -- OP_LOADNIL [A, B]    R(A) := ... := R(B) := nil
      self:addInstruction("LOADNIL", expressionRegister, expressionRegister)
    end
    self:registerVariable(localName, expressionRegister)
  end
end

function CodeGeneratorMethods:compileNumericForLoopNode(node)
  local variableName  = node.VariableName
  local expressions   = node.Expressions
  local codeblock     = node.CodeBlock
  local startRegister = self:processExpressionNode(expressions[1])
  local endRegister   = self:processExpressionNode(expressions[2])
  local stepRegister  = self:allocateRegister()
  if expressions[3] then
    stepRegister = self:processExpressionNode(expressions[3], stepRegister)
  else
    -- OP_LOADK [A, Bx]    R(A) := Kst(Bx)
    self:addInstruction("LOADK", stepRegister, self:findOrCreateConstant(1))
  end
  -- OP_FORPREP [A, sBx]    R(A)-=R(A+2) pc+=sBx
  local forprepInstructionIndex = self:addInstruction("FORPREP", startRegister, 0)
  local loopStart = #self.code
  self:registerVariable(variableName, startRegister)
  local oldBreakInstructions = self.breakInstructions
  self.breakInstructions = {}
  self:processCodeBlock(codeblock)
  local loopEnd = #self.code
  self:updateJumpInstruction(forprepInstructionIndex)
  -- OP_FORLOOP [,A sBx]   R(A)+=R(A+2)
  --                       if R(A) <?= R(A+1) then { pc+=sBx R(A+3)=R(A) }
  self:addInstruction("FORLOOP", startRegister, loopStart - loopEnd - 1)
  self:updateJumpInstructions(self.breakInstructions)
  self.breakInstructions = oldBreakInstructions
  self:unregisterVariable(variableName)
  self:deallocateRegisters({ endRegister, stepRegister }) -- (start register is already deallocated)
end

function CodeGeneratorMethods:compileGenericForLoopNode(node)
  local iteratorVariables   = node.IteratorVariables
  local expressions         = node.Expressions
  local codeblock           = node.CodeBlock
  local expressionRegisters = self:processExpressionNodes(expressions)
  -- OP_JMP [A, sBx]    pc+=sBx
  local startJmpInstructionIndex = self:addInstruction("JMP", 0, 0)
  local forGeneratorRegister = expressionRegisters[1]
  local forStateRegister     = expressionRegisters[2]
  local forControlRegister   = expressionRegisters[3]
  if not (forGeneratorRegister and forStateRegister and forControlRegister) then
    error("Expected 3 expression registers")
  end
  local loopStart = #self.code
  for _, iteratorVariable in ipairs(iteratorVariables) do
    local iteratorRegister = self:allocateRegister()
    self:registerVariable(iteratorVariable, iteratorRegister)
  end
  local oldBreakInstructions = self.breakInstructions
  self.breakInstructions = {}
  self:processCodeBlock(codeblock)
  self:updateJumpInstruction(startJmpInstructionIndex)
  -- OP_TFORLOOP [A, C]    R(A+3), ... ,R(A+2+C) := R(A)(R(A+1), R(A+2))
  --                       if R(A+3) ~= nil then R(A+2)=R(A+3) else pc++
  self:addInstruction("TFORLOOP", forGeneratorRegister, 0, #iteratorVariables)
  -- OP_JMP [A, sBx]    pc+=sBx
  self:addInstruction("JMP", 0, loopStart - #self.code - 1)
  self:updateJumpInstructions(self.breakInstructions)
  self.breakInstructions = oldBreakInstructions
  self:deallocateRegisters(expressionRegisters)
  self:unregisterVariables(iteratorVariables)
end

function CodeGeneratorMethods:compileReturnStatementNode(node)
  local expressionRegisters = self:processExpressionNodes(node.Expressions)
  local startRegister       = expressionRegisters[1] or 0
  local returnAmount        = #node.Expressions + 1
  local lastExpression      = node.Expressions[#node.Expressions]
  if self:isMultiretNode(lastExpression) then
    returnAmount = 0
  end
  -- OP_RETURN [A, B]    return R(A), ... ,R(A+B-2)
  self:addInstruction("RETURN", startRegister, returnAmount, 0)
  self:deallocateRegisters(expressionRegisters) -- Deallocate return expression registers
end

function CodeGeneratorMethods:compileWhileLoopNode(node)
  local loopStart         = #self.code
  local conditionRegister = self:processExpressionNode(node.Condition)
  -- OP_TEST [A, C]    if not (R(A) <=> C) then pc++
  self:addInstruction("TEST", conditionRegister, 0, 0)
  -- OP_JMP [A, sBx]    pc+=sBx
  local jumpInstructionIndex = self:addInstruction("JMP", 0, 0)
  self:deallocateRegister(conditionRegister)
  local oldBreakInstructions = self.breakInstructions
  self.breakInstructions = {}
  self:processCodeBlock(node.CodeBlock)
  -- OP_JMP [A, sBx]    pc+=sBx
  self:addInstruction("JMP", 0, loopStart - #self.code - 1)
  self:updateJumpInstruction(jumpInstructionIndex)
  self:updateJumpInstructions(self.breakInstructions)
  self.breakInstructions = oldBreakInstructions
end

function CodeGeneratorMethods:compileRepeatLoopNode(node)
  local loopStart = #self.code
  self:processCodeBlock(node.CodeBlock)
  local conditionRegister = self:processExpressionNode(node.Condition)
  -- OP_TEST [A, C]    if not (R(A) <=> C) then pc++
  self:addInstruction("TEST", conditionRegister, 0, 0)
  -- OP_JMP [A, sBx]    pc+=sBx
  self:addInstruction("JMP", 0, loopStart - #self.code - 1)
  self:deallocateRegister(conditionRegister)
end

function CodeGeneratorMethods:compileDoBlockNode(node)
  self:processCodeBlock(node.CodeBlock)
end

function CodeGeneratorMethods:compileIfStatementNode(node)
  local branches      = node.Branches
  local elseCodeBlock = node.ElseCodeBlock
  local jumpToEndInstructions = {}
  for index, branch in ipairs(branches) do
    local condition = branch.Condition
    local codeBlock = branch.CodeBlock
    local conditionRegister = self:processExpressionNode(condition)
    -- OP_TEST [A, C]    if not (R(A) <=> C) then pc++
    self:addInstruction("TEST", conditionRegister, 0, 0)
    -- OP_JMP [A, sBx]    pc+=sBx
    local conditionJumpInstructionIndex = self:addInstruction("JMP", 0, 0)
    self:deallocateRegister(conditionRegister)
    self:processCodeBlock(codeBlock)
    if index < #branches or elseCodeBlock then
      -- OP_JMP [A, sBx]    pc+=sBx
      local jumpInstructionIndex = self:addInstruction("JMP", 0, 0)
      table.insert(jumpToEndInstructions, jumpInstructionIndex)
    end
    self:updateJumpInstruction(conditionJumpInstructionIndex)
  end
  if elseCodeBlock then
    self:processCodeBlock(elseCodeBlock)
  end

  self:updateJumpInstructions(jumpToEndInstructions)
end

function CodeGeneratorMethods:compileVariableAssignmentNode(node)
  local expressionRegisters = self:processExpressionNodes(node.Expressions)
  for index, lvalue in ipairs(node.LValues) do
    local lvalueType = lvalue.TYPE
    if lvalueType == "Variable" then
      local variableType = lvalue.VariableType
      local variableName = lvalue.Value
      local expressionRegister = expressionRegisters[index]
      if not expressionRegister then error("Expected an expression for assignment") end
      if variableType == "Local" then
        local variableRegister = self:findVariableRegister(variableName)
        -- OP_MOVE [A, B]    R(A) := R(B)
        self:addInstruction("MOVE", variableRegister, expressionRegister)
      elseif variableType == "Global" then
        -- OP_SETGLOBAL [A, Bx]    Gbl[Kst(Bx)] := R(A)
        self:addInstruction("SETGLOBAL", expressionRegister, self:findOrCreateConstant(variableName))
      elseif variableType == "Upvalue" then
        -- OP_SETUPVAL [A, B]    UpValue[B] := R(A)
        self:addInstruction("SETUPVAL", expressionRegister, self:findOrCreateUpvalue(variableName))
      end
    elseif lvalueType == "TableIndex" then
      local indexRegister = self:processExpressionNode(lvalue.Index)
      local tableExpressionRegister = self:processExpressionNode(lvalue.Expression)
      local expressionRegister = expressionRegisters[index]
      if not expressionRegister then error("Expected an expression for assignment") end
      -- OP_SETTABLE [A, B, C]    R(A)[RK(B)] := RK(C)
      self:addInstruction("SETTABLE", tableExpressionRegister, indexRegister, expressionRegister)
      self:deallocateRegisters({ indexRegister, expressionRegister, tableExpressionRegister })
    else
      error("Unsupported lvalue type: " .. lvalueType)
    end
  end
  self:deallocateRegisters(expressionRegisters)
end

--// Code Generation //--
function CodeGeneratorMethods:processExpressionNode(node, expressionRegister)
  expressionRegister = expressionRegister or self:allocateRegister()
  local nodeType = node.TYPE
  while nodeType == "Expression" do
    node = node.Value
    nodeType = node.TYPE
  end

  if     nodeType == "Number"         then return self:compileNumberNode(node, expressionRegister)
  elseif nodeType == "String"         then return self:compileStringNode(node, expressionRegister)
  elseif nodeType == "Function"       then return self:compileFunctionNode(node, expressionRegister)
  elseif nodeType == "FunctionCall"   then return self:compileFunctionCallNode(node, expressionRegister)
  elseif nodeType == "Constant"       then return self:compileConstantNode(node, expressionRegister)
  elseif nodeType == "VarArg"         then return self:compileVarArgNode(node, expressionRegister)
  elseif nodeType == "TableIndex"     then return self:compileTableIndexNode(node, expressionRegister)
  elseif nodeType == "Table"          then return self:compileTableNode(node, expressionRegister)
  elseif nodeType == "Variable"       then return self:compileVariableNode(node, expressionRegister)
  elseif nodeType == "BinaryOperator" then return self:compileBinaryOperatorNode(node, expressionRegister)
  elseif nodeType == "UnaryOperator"  then return self:compileUnaryOperatorNode(node, expressionRegister)
  end

  error("Unsupported expression node type: " .. tostring(nodeType))
end

function CodeGeneratorMethods:processStatementNode(node)
  local nodeType = node.TYPE
  if nodeType == "FunctionCall" then
    -- Instantly deallocate the register
    self:deallocateRegisters({ self:compileFunctionCallNode(node) })
    return
  elseif nodeType == "BreakStatement"           then return self:compileBreakStatementNode()
  elseif nodeType == "LocalFunctionDeclaration" then return self:compileLocalFunctionDeclarationNode(node)
  elseif nodeType == "FunctionDeclaration"      then return self:compileFunctionDeclarationNode(node)
  elseif nodeType == "LocalDeclaration"         then return self:compileLocalDeclarationNode(node)
  elseif nodeType == "NumericForLoop"           then return self:compileNumericForLoopNode(node)
  elseif nodeType == "GenericForLoop"           then return self:compileGenericForLoopNode(node)
  elseif nodeType == "ReturnStatement"          then return self:compileReturnStatementNode(node)
  elseif nodeType == "WhileLoop"                then return self:compileWhileLoopNode(node)
  elseif nodeType == "RepeatLoop"               then return self:compileRepeatLoopNode(node)
  elseif nodeType == "DoBlock"                  then return self:compileDoBlockNode(node)
  elseif nodeType == "IfStatement"              then return self:compileIfStatementNode(node)
  elseif nodeType == "VariableAssignment"       then return self:compileVariableAssignmentNode(node)
  end

  error("Unsupported statement node type: " .. tostring(nodeType))
end

function CodeGeneratorMethods:processExpressionNodes(list)
  local registers = {}
  for _, node in ipairs(list) do
    local currentExpressionRegisters = { self:processExpressionNode(node) }
    for _, register in ipairs(currentExpressionRegisters) do
      table.insert(registers, register)
    end
  end
  return registers
end

function CodeGeneratorMethods:processCodeBlock(list)
  self:enterScope()
  for _, node in ipairs(list) do
    self:processStatementNode(node)
  end
  self:exitScope()
end

function CodeGeneratorMethods:processFunctionCodeBlock(list, parameters)
  self:enterScope(true) -- Enter with function scope
  for _, parameter in ipairs(parameters) do
    self:registerVariable(parameter, self:allocateRegister())
  end
  for _, node in ipairs(list) do
    self:processStatementNode(node)
  end
  self:exitScope()
end

function CodeGeneratorMethods:processFunction(node, expressionRegister, name)
  local codeBlock    = node.CodeBlock
  local parameters   = node.Parameters or {}
  local isVarArg     = node.IsVarArg
  local oldProto     = self.currentProto
  local proto        = self:newProto()
  proto.numParams    = #parameters
  proto.isVarArg     = isVarArg
  proto.functionName = (name and "@" .. name) or "@anonymous"

  self:processFunctionCodeBlock(codeBlock, parameters)

  -- OP_RETURN [A, B]    return R(A), ... ,R(A+B-2)
  self:addInstruction("RETURN", 0, 1) -- Default return statement
  self:setProto(oldProto)
  table.insert(self.protos, proto)
  -- R(A) := closure(KPROTO[Bx], R(A), ... ,R(A+n))
  self:addInstruction("CLOSURE", expressionRegister, #self.protos - 1)

  for _, upvalueName in ipairs(proto.upvalues) do
    local upvalueType = self:getVariableType(upvalueName)
    if upvalueType == "Local" then
      -- OP_MOVE [A, B]    R(A) := R(B)
      self:addInstruction("MOVE", 0, self:findVariableRegister(upvalueName))
    elseif upvalueType == "Upvalue" then
      -- OP_GETUPVAL [A, B]    R(A) := UpValue[B]
      self:addInstruction("GETUPVAL", 0, self:findOrCreateUpvalue(upvalueName))
    else
      error("Unsupported upvalue type: " .. upvalueType)
    end
  end

  return proto
end

--// Main Code Generation //--
function CodeGeneratorMethods:generate()
  local proto = self:newProto()
  proto.isVarArg = true
  self:processCodeBlock(self.ast)
  -- OP_RETURN [A, B]    return R(A), ... ,R(A+B-2)
  self:addInstruction("RETURN", 0, 1) -- Default return statement
  return proto
end

--* CodeGenerator *--
local CodeGenerator = {}
function CodeGenerator.new(ast)
  local CodeGeneratorInstance = {}

  --// Initialization //--
  CodeGeneratorInstance.ast = ast
  CodeGeneratorInstance.scopes = {}
  CodeGeneratorInstance.breakInstructions = {}
  CodeGeneratorInstance.currentProto = nil

  -- Proto fields extraction
  CodeGeneratorInstance.takenRegisters = {}
  CodeGeneratorInstance.code = nil
  CodeGeneratorInstance.constants = nil
  CodeGeneratorInstance.constantLookup = nil
  CodeGeneratorInstance.upvalues = nil
  CodeGeneratorInstance.upvalueLookup = nil
  CodeGeneratorInstance.protos = nil

  --// Method Binding //--
  insertValues(CodeGeneratorInstance, CodeGeneratorMethods)

  return CodeGeneratorInstance
end


--[[
  ============================================================================
                                    (•_•)?
                              COMPILER CONSTANTS
  ============================================================================
--]]

local MODE_iABC = 0
local MODE_iABx = 1
local MODE_iAsBx = 2

local COMPILER_OPCODE_LOOKUP = {
  ["MOVE"]     = {0, MODE_iABC},  ["LOADK"]     = {1, MODE_iABx},  ["LOADBOOL"] = {2, MODE_iABC},  ["LOADNIL"]   = {3, MODE_iABC},
  ["GETUPVAL"] = {4, MODE_iABC},  ["GETGLOBAL"] = {5, MODE_iABx},  ["GETTABLE"] = {6, MODE_iABC},  ["SETGLOBAL"] = {7, MODE_iABx},
  ["SETUPVAL"] = {8, MODE_iABC},  ["SETTABLE"]  = {9, MODE_iABC},  ["NEWTABLE"] = {10, MODE_iABC}, ["SELF"]      = {11, MODE_iABC},
  ["ADD"]      = {12, MODE_iABC}, ["SUB"]       = {13, MODE_iABC}, ["MUL"]      = {14, MODE_iABC}, ["DIV"]       = {15, MODE_iABC},
  ["MOD"]      = {16, MODE_iABC}, ["POW"]       = {17, MODE_iABC}, ["UNM"]      = {18, MODE_iABC}, ["NOT"]       = {19, MODE_iABC},
  ["LEN"]      = {20, MODE_iABC}, ["CONCAT"]    = {21, MODE_iABC}, ["JMP"]      = {22, MODE_iAsBx},["EQ"]        = {23, MODE_iABC},
  ["LT"]       = {24, MODE_iABC}, ["LE"]        = {25, MODE_iABC}, ["TEST"]     = {26, MODE_iABC}, ["TESTSET"]   = {27, MODE_iABC},
  ["CALL"]     = {28, MODE_iABC}, ["TAILCALL"]  = {29, MODE_iABC}, ["RETURN"]   = {30, MODE_iABC}, ["FORLOOP"]   = {31, MODE_iAsBx},
  ["FORPREP"]  = {32, MODE_iAsBx},["TFORLOOP"]  = {33, MODE_iABC}, ["SETLIST"]  = {34, MODE_iABC}, ["CLOSE"]     = {35, MODE_iABC},
  ["CLOSURE"]  = {36, MODE_iABx}, ["VARARG"]    = {37, MODE_iABC}
}

--[[
  ============================================================================
                                   (۶* ‘ヮ’)۶”
                          !!!!!!!!THE COMPILER!!!!!!!!
  ============================================================================

  The final part of the compiler is the compiler itself (duh). The
  compiler is responsible for converting the given Lua Function Prototypes
  into Lua bytecode. The compiler will implement binary writing logic
  to write the bytecode to a file, which can then be executed by the
--]]

--* CompilerMethods *--
local CompilerMethods = {}

--// Byte Manipulation //--
function CompilerMethods:toUnsigned(value)
  value = value or 0
  return math.max(value, -value - 1)
end

function CompilerMethods:makeBytes(value, byteCount)
  local bytes = {}
  for i = 1, byteCount do
    bytes[i] = value % 256
    value = math.floor(value / 256)
  end
  return string.char(unpack(bytes))
end

function CompilerMethods:makeOneByte(value)
  return string.char(value % 256)
end

function CompilerMethods:makeFourBytes(value)
  return self:makeBytes(value, 4)
end

function CompilerMethods:makeEightBytes(value)
  return self:makeBytes(value, 8)
end

function CompilerMethods:makeDouble(value)
  local sign = (value < 0 and 1) or 0
  local mantissa, exponent = math.frexp(math.abs(value))

  if value == 0 then -- zero
    mantissa, exponent = 0, 0
  elseif value == 1/0 then -- infinity
    mantissa, exponent = 0, 2047
  else
    mantissa = (mantissa * 2 - 1) * (0.5 * (2 ^ 53))
    exponent = exponent + 1022
  end

  -- 52-bit mantissa
  local double = {}
  for index = 1, 6 do
    double[index] = mantissa % 256
    mantissa = math.floor(mantissa / 256)
  end

  -- exponent (11 bit)
  double[7] = ((mantissa % 16) + (exponent % 16) * 16) % 256
  double[8] = ((sign * 128) + math.floor(exponent / 16)) % 256
  return string.char(unpack(double))
end

--// Bytecode Generation //--
function CompilerMethods:makeString(value)
  value = value .. "\0"
  local size = self:makeEightBytes(#value)
  return size .. value
end

function CompilerMethods:makeConstant(constantValue, constantType)
  if constantType == "number" then
    return self:makeOneByte(3) .. self:makeDouble(constantValue)
  elseif constantType == "string" then
    return self:makeOneByte(4) .. self:makeString(constantValue)
  elseif constantType == "boolean" then
    local secondByte = (constantValue and 1) or 0
    return self:makeOneByte(1) .. self:makeOneByte(secondByte)
  elseif constantType == "nil" then
    return self:makeOneByte(0)
  end
  error("Unsupported constant type: " .. constantType)
end

function CompilerMethods:makeInstruction(instruction)
  local opcodeTable = COMPILER_OPCODE_LOOKUP[instruction[1]]
  local opcode, opmode = unpack(opcodeTable)
  local a = self:toUnsigned(instruction[2])
  local instructionNumber = opcode
  instructionNumber = instructionNumber + (a * 64) -- a << 6
  if opmode == MODE_iABC then
    local b = self:toUnsigned(instruction[3])
    local c = self:toUnsigned(instruction[4])
    instructionNumber = instructionNumber + (b * 8388608) -- b << 23
    instructionNumber = instructionNumber + (c * 16384)   -- c << 14
  elseif opmode == MODE_iABx then
    local b = self:toUnsigned(instruction[3])
    instructionNumber = instructionNumber + (b * 16384) -- b << 14
  elseif opmode == MODE_iAsBx then
    local b = instruction[3]
    instructionNumber = instructionNumber + ((b + 131071) * 16384) -- (b + 131071) << 14
  end
  return self:makeFourBytes(instructionNumber)
end

function CompilerMethods:makeConstantSection(proto)
  local constantSection = self:makeFourBytes(#proto.constants) -- Number of constants
  for _, constant in ipairs(proto.constants) do
    local constantType = type(constant)
    constantSection = constantSection .. self:makeConstant(constant, constantType)
  end
  constantSection = constantSection .. self:makeFourBytes(#proto.protos) -- Number of protos
  for _, childProto in ipairs(proto.protos) do
    constantSection = constantSection .. self:makeFunction(childProto)
  end
  return constantSection
end

function CompilerMethods:makeCodeSection(proto)
  local codeSection = self:makeFourBytes(#proto.code) -- Number of instructions
  for _, instruction in ipairs(proto.code) do
    codeSection = codeSection .. self:makeInstruction(instruction)
  end
  return codeSection
end

function CompilerMethods:makeFunction(proto)
  local functionHeader = self:makeString(proto.functionName)                       -- Function name
  functionHeader = functionHeader .. self:makeFourBytes(0)                         -- Line defined
  functionHeader = functionHeader .. self:makeFourBytes(0)                         -- Last line defined
  functionHeader = functionHeader .. self:makeOneByte(#proto.upvalues)             -- nups (Number of upvalues)
  functionHeader = functionHeader .. self:makeOneByte(proto.numParams)             -- Number of parameters
  functionHeader = functionHeader .. self:makeOneByte((proto.isVarArg and 2) or 0) -- Is vararg
  functionHeader = functionHeader .. self:makeOneByte(128)                         -- Max stack size
  functionHeader = functionHeader .. self:makeCodeSection(proto)                   -- Code section
  functionHeader = functionHeader .. self:makeConstantSection(proto)               -- Constant section
  functionHeader = functionHeader .. self:makeFourBytes(0)                         -- Line info
  functionHeader = functionHeader .. self:makeFourBytes(0)                         -- Local variables
  functionHeader = functionHeader .. self:makeFourBytes(0)                         -- Upvalues

  return functionHeader
end

function CompilerMethods:makeHeader()
  local header = "\27Lua"              -- Signature
  header = header .. string.char(0x51) -- Version 5.1
  header = header .. "\0"              -- Format 0 (official)
  header = header .. "\1"              -- Little endian
  header = header .. "\4"              -- sizeof(int)
  header = header .. "\8"              -- sizeof(size_t)
  header = header .. "\4"              -- sizeof(Instruction)
  header = header .. "\8"              -- sizeof(lua_Number)
  header = header .. "\0"              -- Integral flag
  return header
end

--// Main //--
function CompilerMethods:compile()
  local header = self:makeHeader()
  local functionHeader = self:makeFunction(self.mainProto)
  return header .. functionHeader
end

--* Compiler *--
local Compiler = {}
function Compiler.new(mainProto)
  local CompilerInstance = {}

  --// Initialization //--
  CompilerInstance.mainProto = mainProto

  --// Method Binding //--
  insertValues(CompilerInstance, CompilerMethods)

  return CompilerInstance
end

-- Now I'm just exporting everything...
return {
  Tokenizer     = Tokenizer,
  Parser        = Parser,
  CodeGenerator = CodeGenerator,
  Compiler      = Compiler
}