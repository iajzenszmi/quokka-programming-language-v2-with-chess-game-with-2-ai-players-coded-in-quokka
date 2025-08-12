program QuokkaCompilerVM;

{$mode objfpc}{$H+}

uses
  SysUtils, Classes;

type
  TTokenKind = (
    tkEOF, tkIdent, tkNumber, tkString,
    tkLet, tkPrint, tkIf, tkElse, tkWhile, tkFunc, tkReturn,
    tkLParen, tkRParen, tkLBrace, tkRBrace,
    tkLBracket, tkRBracket,
    tkComma, tkSemicolon, tkAssign,
    tkPlus, tkMinus, tkStar, tkSlash, tkPercent,
    tkBang, tkEq, tkNe, tkLt, tkLe, tkGt, tkGe,
    tkAmp, tkBar, tkCaret, tkTilde, tkShl, tkShr,
    tkAndAnd, tkOrOr
  );

  TToken = record
    kind: TTokenKind;
    lex: string;   // for identifiers & strings
    ival: Int64;   // for numbers
    line: integer;
    col: integer;
  end;

  TIntArray = array of Int64;
  TStringArray = array of string;

const
  // Bytecode opcodes
  OP_HALT   = 0;
  OP_ICONST = 1;   // value (Int64)
  OP_SCONST = 2;   // string id (integer)
  OP_ADD    = 3;
  OP_SUB    = 4;
  OP_MUL    = 5;
  OP_DIV    = 6;
  OP_MOD    = 7;
  OP_NEG    = 8;
  OP_NOT    = 9;   // logical not (0->1, else 1->0) on int
  OP_EQ     = 10;
  OP_NE     = 11;
  OP_LT     = 12;
  OP_LE     = 13;
  OP_GT     = 14;
  OP_GE     = 15;
  OP_JMP    = 16;  // addr
  OP_JZ     = 17;  // addr if false
  OP_LOAD   = 18;  // local slot
  OP_STORE  = 19;  // local slot
  OP_CALL   = 20;  // funcIndex, argc
  OP_RET    = 21;
  OP_PRINT  = 22;
  OP_POP    = 23;
  OP_ENTER  = 24;  // nlocals
  // Arrays / strings / bits / shifts / logical
  OP_ANEW   = 25;  // pop length -> push array
  OP_AGET   = 26;  // pop idx, arr -> push int
  OP_ASET   = 27;  // pop val, idx, arr -> (store)
  OP_LEN    = 28;  // pop val -> push int (len of str/array)
  OP_BAND   = 29;
  OP_BOR    = 30;
  OP_BXOR   = 31;
  OP_BNOT   = 32;
  OP_SHL    = 33;
  OP_SHR    = 34;
  OP_LAND   = 35;
  OP_LOR    = 36;

type
  TFunctionInfo = record
    name: string;
    paramCount: integer;
    localCount: integer;
    addr: integer; // code start index
  end;

  TFuncArray = array of TFunctionInfo;

  TValueKind = (vkInt, vkStr, vkArr);

  TValue = record
    k: TValueKind;
    i: Int64;     // for vkInt
    sid: integer; // for vkStr
    aid: integer; // for vkArr
  end;

  TValueArray = array of TValue;

var
  // Source / lexer
  Source: string;
  SLen: integer;
  SPos: integer;
  SLine, SCol: integer;
  Cur: TToken;

  // IR
  Code: TIntArray;
  Funcs: TFuncArray;

  // Locals
  LocalNames: TStringArray;
  CurrentEnterPos: integer = -1;
  CurrentFuncIndex: integer = -1;

  // Options
  OptDumpOnly: boolean = false;
  BootIP: integer = 0;

  // Runtime heaps
  StrHeap: TStringArray;
  ArrHeap: array of array of Int64; // dynamic Int64 buffers

procedure ErrorAt(line, col: integer; const msg: string);
begin
  Writeln(StdErr, 'Error [', line, ':', col, ']: ', msg);
  Halt(1);
end;

procedure ErrorTok(const T: TToken; const msg: string);
begin
  ErrorAt(T.line, T.col, msg);
end;

function IsAlpha(ch: char): boolean; inline;
begin
  Result := (ch in ['A'..'Z','a'..'z','_']);
end;

function IsDigit(ch: char): boolean; inline;
begin
  Result := (ch in ['0'..'9']);
end;

function PeekChar(offset: integer = 0): char; inline;
var p: integer;
begin
  p := SPos + offset;
  if (p >= 1) and (p <= SLen) then Result := Source[p]
  else Result := #0;
end;

procedure AdvChar;
var ch: char;
begin
  if SPos <= SLen then
  begin
    ch := Source[SPos];
    Inc(SPos);
    if ch = #10 then begin Inc(SLine); SCol := 1; end
    else Inc(SCol);
  end;
end;

function MakeToken(k: TTokenKind; const lex: string = ''; ival: Int64 = 0): TToken;
begin
  Result.kind := k; Result.lex := lex; Result.ival := ival;
  Result.line := SLine; Result.col := SCol;
end;

function KeywordKind(const s: string): TTokenKind;
begin
  if s = 'let' then exit(tkLet);
  if s = 'print' then exit(tkPrint);
  if s = 'if' then exit(tkIf);
  if s = 'else' then exit(tkElse);
  if s = 'while' then exit(tkWhile);
  if s = 'func' then exit(tkFunc);
  if s = 'return' then exit(tkReturn);
  Result := tkIdent;
end;

function ReadStringLiteral: string;
var ch: char; s: string;
begin
  // opening quote already current; consume it
  AdvChar;
  s := '';
  while true do
  begin
    ch := PeekChar;
    if ch = #0 then ErrorAt(SLine, SCol, 'Unterminated string literal');
    if ch = '"' then begin AdvChar; break; end;
    if ch = '\' then
    begin
      AdvChar; ch := PeekChar;
      if ch = #0 then ErrorAt(SLine, SCol, 'Bad escape');
      case ch of
        'n': s := s + #10;
        't': s := s + #9;
        '"': s := s + '"';
        '\': s := s + '\';
      else
        s := s + ch;
      end;
      AdvChar;
    end
    else begin s := s + ch; AdvChar; end;
  end;
  Result := s;
end;

procedure NextToken;
var ch: char; startLine, startCol: integer; s: string; num: Int64;
begin
  // skip whitespace/comments
  while true do
  begin
    ch := PeekChar;
    while (ch <> #0) and (ch <= ' ') do begin AdvChar; ch := PeekChar; end;
    if (ch = '/') and (PeekChar(1) = '/') then
    begin while (ch <> #0) and (ch <> #10) do begin AdvChar; ch := PeekChar; end; continue; end;
    if (ch = '/') and (PeekChar(1) = '*') then
    begin
      AdvChar; AdvChar;
      while true do
      begin
        ch := PeekChar;
        if ch = #0 then ErrorAt(SLine, SCol, 'Unterminated block comment');
        if (ch = '*') and (PeekChar(1) = '/') then begin AdvChar; AdvChar; break; end;
        AdvChar;
      end;
      continue;
    end;
    break;
  end;

  startLine := SLine; startCol := SCol;

  ch := PeekChar;
  if ch = #0 then begin Cur := MakeToken(tkEOF); Cur.line:=startLine; Cur.col:=startCol; exit; end;

  if IsAlpha(ch) then
  begin
    s := '';
    while IsAlpha(PeekChar) or IsDigit(PeekChar) do begin s := s + PeekChar; AdvChar; end;
    Cur := MakeToken(KeywordKind(s), s, 0); Cur.line := startLine; Cur.col := startCol; exit;
  end;

  if IsDigit(ch) then
  begin
    s := '';
    while IsDigit(PeekChar) do begin s := s + PeekChar; AdvChar; end;
    num := StrToInt64(s);
    Cur := MakeToken(tkNumber, s, num); Cur.line := startLine; Cur.col := startCol; exit;
  end;

  case ch of
    '"': begin s := ReadStringLiteral; Cur := MakeToken(tkString, s, 0); Cur.line:=startLine; Cur.col:=startCol; exit; end;
    '(': begin AdvChar; Cur := MakeToken(tkLParen); end;
    ')': begin AdvChar; Cur := MakeToken(tkRParen); end;
    '{': begin AdvChar; Cur := MakeToken(tkLBrace); end;
    '}': begin AdvChar; Cur := MakeToken(tkRBrace); end;
    '[': begin AdvChar; Cur := MakeToken(tkLBracket); end;
    ']': begin AdvChar; Cur := MakeToken(tkRBracket); end;
    ',': begin AdvChar; Cur := MakeToken(tkComma); end;
    ';': begin AdvChar; Cur := MakeToken(tkSemicolon); end;
    '+': begin AdvChar; Cur := MakeToken(tkPlus); end;
    '-': begin AdvChar; Cur := MakeToken(tkMinus); end;
    '*': begin AdvChar; Cur := MakeToken(tkStar); end;
    '/': begin AdvChar; Cur := MakeToken(tkSlash); end;
    '%': begin AdvChar; Cur := MakeToken(tkPercent); end;
    '!':
      begin
        AdvChar;
        if PeekChar = '=' then begin AdvChar; Cur := MakeToken(tkNe); end
        else Cur := MakeToken(tkBang);
      end;
    '=':
      begin
        AdvChar;
        if PeekChar = '=' then begin AdvChar; Cur := MakeToken(tkEq); end
        else Cur := MakeToken(tkAssign);
      end;
    '<':
      begin
        AdvChar;
        if PeekChar = '<' then begin AdvChar; Cur := MakeToken(tkShl); end
        else if PeekChar = '=' then begin AdvChar; Cur := MakeToken(tkLe); end
        else Cur := MakeToken(tkLt);
      end;
    '>':
      begin
        AdvChar;
        if PeekChar = '>' then begin AdvChar; Cur := MakeToken(tkShr); end
        else if PeekChar = '=' then begin AdvChar; Cur := MakeToken(tkGe); end
        else Cur := MakeToken(tkGt);
      end;
    '&':
      begin
        AdvChar;
        if PeekChar = '&' then begin AdvChar; Cur := MakeToken(tkAndAnd); end
        else Cur := MakeToken(tkAmp);
      end;
    '|':
      begin
        AdvChar;
        if PeekChar = '|' then begin AdvChar; Cur := MakeToken(tkOrOr); end
        else Cur := MakeToken(tkBar);
      end;
    '^': begin AdvChar; Cur := MakeToken(tkCaret); end;
    '~': begin AdvChar; Cur := MakeToken(tkTilde); end;
  else
    ErrorAt(startLine, startCol, 'Unexpected character: "'+ch+'"');
  end;
  Cur.line := startLine; Cur.col := startCol;
end;

procedure Expect(k: TTokenKind; const msg: string = '');
begin
  if Cur.kind <> k then ErrorTok(Cur, 'Expected token ' + IntToStr(Ord(k)) + ' ' + msg + ', got ' + IntToStr(Ord(Cur.kind)));
  NextToken;
end;

function Accept(k: TTokenKind): boolean;
begin
  if Cur.kind = k then begin NextToken; exit(true); end;
  Result := false;
end;

function Emit(op: Int64): integer;
begin
  Result := Length(Code);
  SetLength(Code, Result+1);
  Code[Result] := op;
end;

function Emit2(op, a: Int64): integer;
begin
  Result := Emit(op); Emit(a);
end;

function Emit3(op, a, b: Int64): integer;
begin
  Result := Emit(op); Emit(a); Emit(b);
end;

procedure Patch(atIndex: integer; value: Int64);
begin
  if (atIndex < 0) or (atIndex >= Length(Code)) then ErrorAt(0,0,'Internal patch out of range');
  Code[atIndex] := value;
end;

function LocalIndexOf(const name: string): integer;
var i: integer;
begin
  for i := 0 to High(LocalNames) do if LocalNames[i] = name then exit(i);
  Result := -1;
end;

function AddLocal(const name: string): integer;
var idx: integer;
begin
  idx := LocalIndexOf(name);
  if idx >= 0 then exit(idx);
  idx := Length(LocalNames);
  SetLength(LocalNames, idx+1);
  LocalNames[idx] := name;
  Result := idx;
  if idx+1 > Funcs[CurrentFuncIndex].localCount then Funcs[CurrentFuncIndex].localCount := idx+1;
end;

function FuncIndexOf(const name: string): integer;
var i: integer;
begin
  for i := 0 to High(Funcs) do if Funcs[i].name = name then exit(i);
  Result := -1;
end;

function AddFuncShell(const name: string; paramCount: integer): integer;
var idx: integer;
begin
  idx := FuncIndexOf(name);
  if idx >= 0 then exit(idx);
  idx := Length(Funcs);
  SetLength(Funcs, idx+1);
  Funcs[idx].name := name;
  Funcs[idx].paramCount := paramCount;
  Funcs[idx].localCount := paramCount;
  Funcs[idx].addr := -1;
  Result := idx;
end;

// String heap helper
function StrAdd(const s: string): integer;
var id: integer;
begin
  id := Length(StrHeap);
  SetLength(StrHeap, id+1);
  StrHeap[id] := s;
  Result := id;
end;

// ---- Parser forwards ----
procedure ParseProgram; forward;
procedure ParseFunction; forward;
procedure ParseBlock; forward;
procedure ParseStmt; forward;
procedure ParseIfStmt; forward;
procedure ParseWhileStmt; forward;
procedure ParseReturnStmt; forward;
procedure ParseLetOrAssignOrCall; forward;
procedure ParsePrintStmt; forward;

procedure Expr; forward;          // top: logical OR
procedure LOrExpr; forward;
procedure LAndExpr; forward;
procedure OrExpr; forward;
procedure XorExpr; forward;
procedure AndExpr; forward;
procedure EqualityExpr; forward;
procedure ComparisonExpr; forward;
procedure ShiftExpr; forward;
procedure TermExpr; forward;
procedure FactorExpr; forward;
procedure UnaryExpr; forward;
procedure PrimaryExpr; forward;

function IsStartOfStmt: boolean;
begin
  case Cur.kind of
    tkLet, tkIf, tkWhile, tkReturn, tkPrint, tkLBrace, tkIdent: exit(true);
  else
    exit(false);
  end;
end;

// ---- Expressions ----

procedure Expr; begin LOrExpr; end;

procedure LOrExpr;
begin
  LAndExpr;
  while Cur.kind = tkOrOr do begin NextToken; LAndExpr; Emit(OP_LOR); end;
end;

procedure LAndExpr;
begin
  OrExpr;
  while Cur.kind = tkAndAnd do begin NextToken; OrExpr; Emit(OP_LAND); end;
end;

procedure OrExpr;
begin
  XorExpr;
  while Cur.kind = tkBar do begin NextToken; XorExpr; Emit(OP_BOR); end;
end;

procedure XorExpr;
begin
  AndExpr;
  while Cur.kind = tkCaret do begin NextToken; AndExpr; Emit(OP_BXOR); end;
end;

procedure AndExpr;
begin
  EqualityExpr;
  while Cur.kind = tkAmp do begin NextToken; EqualityExpr; Emit(OP_BAND); end;
end;

procedure EqualityExpr;
begin
  ComparisonExpr;
  while (Cur.kind = tkEq) or (Cur.kind = tkNe) do
  begin
    if Cur.kind = tkEq then begin NextToken; ComparisonExpr; Emit(OP_EQ); end
    else begin NextToken; ComparisonExpr; Emit(OP_NE); end;
  end;
end;

procedure ComparisonExpr;
begin
  ShiftExpr;
  while (Cur.kind = tkLt) or (Cur.kind = tkLe) or (Cur.kind = tkGt) or (Cur.kind = tkGe) do
  begin
    case Cur.kind of
      tkLt: begin NextToken; ShiftExpr; Emit(OP_LT); end;
      tkLe: begin NextToken; ShiftExpr; Emit(OP_LE); end;
      tkGt: begin NextToken; ShiftExpr; Emit(OP_GT); end;
      tkGe: begin NextToken; ShiftExpr; Emit(OP_GE); end;
    end;
  end;
end;

procedure ShiftExpr;
begin
  TermExpr;
  while (Cur.kind = tkShl) or (Cur.kind = tkShr) do
  begin
    if Cur.kind = tkShl then begin NextToken; TermExpr; Emit(OP_SHL); end
    else begin NextToken; TermExpr; Emit(OP_SHR); end;
  end;
end;

procedure TermExpr;
begin
  FactorExpr;
  while (Cur.kind = tkPlus) or (Cur.kind = tkMinus) do
  begin
    if Cur.kind = tkPlus then begin NextToken; FactorExpr; Emit(OP_ADD); end
    else begin NextToken; FactorExpr; Emit(OP_SUB); end;
  end;
end;

procedure FactorExpr;
begin
  UnaryExpr;
  while (Cur.kind = tkStar) or (Cur.kind = tkSlash) or (Cur.kind = tkPercent) do
  begin
    case Cur.kind of
      tkStar:    begin NextToken; UnaryExpr; Emit(OP_MUL); end;
      tkSlash:   begin NextToken; UnaryExpr; Emit(OP_DIV); end;
      tkPercent: begin NextToken; UnaryExpr; Emit(OP_MOD); end;
    end;
  end;
end;

procedure UnaryExpr;
begin
  if Accept(tkMinus) then begin UnaryExpr; Emit(OP_NEG); end
  else if Accept(tkBang) then begin UnaryExpr; Emit(OP_NOT); end
  else if Accept(tkTilde) then begin UnaryExpr; Emit(OP_BNOT); end
  else PrimaryExpr;
end;

procedure ParseArgList(out argc: integer);
begin
  argc := 0;
  if not Accept(tkRParen) then
  begin
    repeat
      Expr;
      Inc(argc);
    until not Accept(tkComma);
    Expect(tkRParen, ')');
  end;
end;

procedure PrimaryExpr;
var name: string; idx, fidx, argc: integer;
begin
  if Cur.kind = tkNumber then
  begin
    Emit2(OP_ICONST, Cur.ival); NextToken;
  end
  else if Cur.kind = tkString then
  begin
    idx := StrAdd(Cur.lex);
    Emit2(OP_SCONST, idx);
    NextToken;
  end
  else if Accept(tkLParen) then
  begin
    Expr;
    Expect(tkRParen, ') expected');
  end
  else if Cur.kind = tkIdent then
  begin
    name := Cur.lex; NextToken;
    // Call?
    if Accept(tkLParen) then
    begin
      ParseArgList(argc);
      if name = 'array' then
      begin
        if argc <> 1 then ErrorAt(Cur.line, Cur.col, 'array(n) expects 1 arg');
        Emit(OP_ANEW);
      end
      else if name = 'len' then
      begin
        if argc <> 1 then ErrorAt(Cur.line, Cur.col, 'len(x) expects 1 arg');
        Emit(OP_LEN);
      end
      else
      begin
        fidx := FuncIndexOf(name);
        if fidx < 0 then fidx := AddFuncShell(name, -1);
        Emit3(OP_CALL, fidx, argc);
      end;
    end
    // Indexing: name[expr]
    else if Accept(tkLBracket) then
    begin
      idx := LocalIndexOf(name);
      if idx < 0 then ErrorAt(Cur.line, Cur.col, 'Unknown array "'+name+'"');
      Emit2(OP_LOAD, idx); // push array value
      Expr; Expect(tkRBracket, ']');
      Emit(OP_AGET);
    end
    else
    begin
      idx := LocalIndexOf(name);
      if idx < 0 then ErrorAt(Cur.line, Cur.col, 'Unknown variable "'+name+'"');
      Emit2(OP_LOAD, idx);
    end;
  end
  else
    ErrorTok(Cur, 'Expression expected');
end;

// ---- Statements ----

procedure ParseBlock;
begin
  Expect(tkLBrace, '{');
  while IsStartOfStmt do ParseStmt;
  Expect(tkRBrace, '}');
end;

procedure ParseIfStmt;
var jzPos, jmpEndPos: integer;
begin
  Expect(tkIf, 'if');
  Expect(tkLParen, '(');
  Expr;
  Expect(tkRParen, ')');
  jzPos := Emit2(OP_JZ, -1);         // jump to else (or end) if false
  // THEN
  ParseBlock;
  if Accept(tkElse) then
  begin
    jmpEndPos := Emit2(OP_JMP, -1);  // skip ELSE after THEN
    Patch(jzPos+1, Length(Code));    // false jumps here => start of ELSE
    // ELSE
    ParseBlock;
    Patch(jmpEndPos+1, Length(Code)); // end of IF
  end
  else
  begin
    Patch(jzPos+1, Length(Code));     // false jumps past THEN
  end;
end;

procedure ParseWhileStmt;
var startPos, jzPos: integer;
begin
  Expect(tkWhile, 'while');
  startPos := Length(Code);
  Expect(tkLParen, '(');
  Expr;
  Expect(tkRParen, ')');
  jzPos := Emit2(OP_JZ, -1);
  ParseBlock;
  Emit2(OP_JMP, startPos);
  Patch(jzPos+1, Length(Code));
end;

procedure ParseReturnStmt;
begin
  Expect(tkReturn, 'return');
  Expr;
  Expect(tkSemicolon, ';');
  Emit(OP_RET);
end;

procedure ParsePrintStmt;
begin
  Expect(tkPrint, 'print');
  Expr;
  Expect(tkSemicolon, ';');
  Emit(OP_PRINT);
end;

procedure ParseLetOrAssignOrCall;
var
  name: string;
  slot, argc, fidx: integer;
  isIndex: boolean;
begin
  if Accept(tkLet) then
  begin
    if Cur.kind <> tkIdent then ErrorTok(Cur,'identifier expected after let');
    name := Cur.lex; NextToken;
    Expect(tkAssign, '=');
    Expr;
    Expect(tkSemicolon, ';');
    slot := AddLocal(name);
    Emit2(OP_STORE, slot);
  end
  else if Cur.kind = tkIdent then
  begin
    name := Cur.lex; NextToken;

    // Call as statement?
    if Accept(tkLParen) then
    begin
      ParseArgList(argc);
      if name = 'array' then
      begin
        if argc<>1 then ErrorAt(Cur.line,Cur.col,'array(n) expects 1');
        Emit(OP_ANEW);   // create
        Emit(OP_POP);    // discard in stmt context
      end
      else if name = 'len' then
      begin
        if argc<>1 then ErrorAt(Cur.line,Cur.col,'len(x) expects 1');
        Emit(OP_LEN);
        Emit(OP_POP);
      end
      else
      begin
        fidx := FuncIndexOf(name);
        if fidx < 0 then fidx := AddFuncShell(name, -1);
        Emit3(OP_CALL, fidx, argc);
        Emit(OP_POP); // discard result
      end;
      Expect(tkSemicolon, ';');
      exit;
    end;

    // Assignment (variable or array element)
    isIndex := Accept(tkLBracket);
    if isIndex then
    begin
      slot := LocalIndexOf(name);
      if slot < 0 then ErrorAt(Cur.line, Cur.col, 'Unknown array "'+name+'"');
      Emit2(OP_LOAD, slot); // arr
      Expr; Expect(tkRBracket, ']');
      Expect(tkAssign, '=');
      Expr; Expect(tkSemicolon, ';');
      Emit(OP_ASET);
    end
    else
    begin
      Expect(tkAssign, '=');
      Expr; Expect(tkSemicolon, ';');
      slot := LocalIndexOf(name);
      if slot < 0 then ErrorAt(Cur.line, Cur.col, 'Unknown variable "'+name+'"');
      Emit2(OP_STORE, slot);
    end;
  end
  else
    ErrorTok(Cur, 'Statement expected');
end;

procedure ParseStmt;
begin
  case Cur.kind of
    tkLBrace: ParseBlock;
    tkIf: ParseIfStmt;
    tkWhile: ParseWhileStmt;
    tkReturn: ParseReturnStmt;
    tkPrint: ParsePrintStmt;
    tkLet, tkIdent: ParseLetOrAssignOrCall;
  else
    ErrorTok(Cur, 'Unexpected token in statement');
  end;
end;

procedure ParseParamList(out names: TStringArray; out count: integer);
begin
  SetLength(names, 0); count := 0;
  if Accept(tkRParen) then exit;
  repeat
    if Cur.kind <> tkIdent then ErrorTok(Cur, 'parameter name expected');
    SetLength(names, Length(names)+1);
    names[High(names)] := Cur.lex;
    Inc(count);
    NextToken;
  until not Accept(tkComma);
  Expect(tkRParen, ')');
end;

procedure ParseFunction;
var fname: string; paramNames: TStringArray; paramCount,i: integer;
begin
  Expect(tkFunc, 'func');
  if Cur.kind <> tkIdent then ErrorTok(Cur,'function name expected');
  fname := Cur.lex; NextToken;
  Expect(tkLParen, '(');
  ParseParamList(paramNames, paramCount);

  CurrentFuncIndex := AddFuncShell(fname, paramCount);
  Funcs[CurrentFuncIndex].paramCount := paramCount;
  Funcs[CurrentFuncIndex].localCount := paramCount;
  Funcs[CurrentFuncIndex].addr := Length(Code);

  SetLength(LocalNames, 0);
  for i := 0 to paramCount-1 do AddLocal(paramNames[i]);

  CurrentEnterPos := Emit2(OP_ENTER, -1); // patched later

  ParseBlock;

  Emit2(OP_ICONST, 0);
  Emit(OP_RET);

  Patch(CurrentEnterPos+1, Funcs[CurrentFuncIndex].localCount - Funcs[CurrentFuncIndex].paramCount);

  CurrentFuncIndex := -1;
  CurrentEnterPos := -1;
  SetLength(LocalNames, 0);
end;

procedure ParseProgram;
var mainIdx: integer;
begin
  while Cur.kind <> tkEOF do ParseFunction;
  mainIdx := FuncIndexOf('main');
  if mainIdx < 0 then ErrorAt(1,1,'No entry point: define func main()');
  BootIP := Length(Code);
  Emit3(OP_CALL, mainIdx, 0);
  Emit(OP_HALT);
end;

// ---- Disassembler ----
procedure DumpCode;
var i: integer;
begin
  i := 0;
  Writeln('== Functions ==');
  for i := 0 to High(Funcs) do
    Writeln('  [', i, '] ', Funcs[i].name, ' params=', Funcs[i].paramCount,
            ' locals=', Funcs[i].localCount, ' addr=', Funcs[i].addr);
  Writeln('== Bytecode ==');
  i := 0;
  while i < Length(Code) do
  begin
    Write(Format('%5d: ', [i]));
    case Code[i] of
      OP_HALT:   begin Writeln('HALT'); Inc(i,1); end;
      OP_ICONST: begin Writeln('ICONST ', Code[i+1]); Inc(i,2); end;
      OP_SCONST: begin Writeln('SCONST "', StrHeap[integer(Code[i+1])], '"'); Inc(i,2); end;
      OP_ADD:    begin Writeln('ADD'); Inc(i,1); end;
      OP_SUB:    begin Writeln('SUB'); Inc(i,1); end;
      OP_MUL:    begin Writeln('MUL'); Inc(i,1); end;
      OP_DIV:    begin Writeln('DIV'); Inc(i,1); end;
      OP_MOD:    begin Writeln('MOD'); Inc(i,1); end;
      OP_NEG:    begin Writeln('NEG'); Inc(i,1); end;
      OP_NOT:    begin Writeln('NOT'); Inc(i,1); end;
      OP_EQ:     begin Writeln('EQ'); Inc(i,1); end;
      OP_NE:     begin Writeln('NE'); Inc(i,1); end;
      OP_LT:     begin Writeln('LT'); Inc(i,1); end;
      OP_LE:     begin Writeln('LE'); Inc(i,1); end;
      OP_GT:     begin Writeln('GT'); Inc(i,1); end;
      OP_GE:     begin Writeln('GE'); Inc(i,1); end;
      OP_JMP:    begin Writeln('JMP ', Code[i+1]); Inc(i,2); end;
      OP_JZ:     begin Writeln('JZ  ', Code[i+1]); Inc(i,2); end;
      OP_LOAD:   begin Writeln('LOAD ', Code[i+1]); Inc(i,2); end;
      OP_STORE:  begin Writeln('STORE ', Code[i+1]); Inc(i,2); end;
      OP_CALL:   begin Writeln('CALL f=', Code[i+1], ' argc=', Code[i+2]); Inc(i,3); end;
      OP_RET:    begin Writeln('RET'); Inc(i,1); end;
      OP_PRINT:  begin Writeln('PRINT'); Inc(i,1); end;
      OP_POP:    begin Writeln('POP'); Inc(i,1); end;
      OP_ENTER:  begin Writeln('ENTER ', Code[i+1]); Inc(i,2); end;
      OP_ANEW:   begin Writeln('ANEW'); Inc(i,1); end;
      OP_AGET:   begin Writeln('AGET'); Inc(i,1); end;
      OP_ASET:   begin Writeln('ASET'); Inc(i,1); end;
      OP_LEN:    begin Writeln('LEN'); Inc(i,1); end;
      OP_BAND:   begin Writeln('BAND'); Inc(i,1); end;
      OP_BOR:    begin Writeln('BOR'); Inc(i,1); end;
      OP_BXOR:   begin Writeln('BXOR'); Inc(i,1); end;
      OP_BNOT:   begin Writeln('BNOT'); Inc(i,1); end;
      OP_SHL:    begin Writeln('SHL'); Inc(i,1); end;
      OP_SHR:    begin Writeln('SHR'); Inc(i,1); end;
      OP_LAND:   begin Writeln('LAND'); Inc(i,1); end;
      OP_LOR:    begin Writeln('LOR'); Inc(i,1); end;
    else
      Writeln('??? (', Code[i], ')'); Inc(i,1);
    end;
  end;
end;

// ---- VM helpers ----
function VInt(x: Int64): TValue; var v: TValue; begin v.k := vkInt; v.i := x; v.sid := -1; v.aid := -1; Result := v; end;
function VStr(id: integer): TValue; var v: TValue; begin v.k := vkStr; v.sid := id; v.i := 0; v.aid := -1; Result := v; end;
function VArr(id: integer): TValue; var v: TValue; begin v.k := vkArr; v.aid := id; v.i := 0; v.sid := -1; Result := v; end;

function ArrNew(n: integer): integer;
var id: integer;
begin
  if n < 0 then ErrorAt(0,0,'array length must be >= 0');
  id := Length(ArrHeap);
  SetLength(ArrHeap, id+1);
  SetLength(ArrHeap[id], n);
  Result := id;
end;

function ArrLen(aid: integer): integer;
begin
  if (aid < 0) or (aid > High(ArrHeap)) then ErrorAt(0,0,'bad array handle');
  Result := Length(ArrHeap[aid]);
end;

function ArrGet(aid, idx: integer): Int64;
begin
  if (aid < 0) or (aid > High(ArrHeap)) then ErrorAt(0,0,'bad array handle');
  if (idx < 0) or (idx >= Length(ArrHeap[aid])) then ErrorAt(0,0,'array index out of range');
  Result := ArrHeap[aid][idx];
end;

procedure ArrSet(aid, idx: integer; val: Int64);
begin
  if (aid < 0) or (aid > High(ArrHeap)) then ErrorAt(0,0,'bad array handle');
  if (idx < 0) or (idx >= Length(ArrHeap[aid])) then ErrorAt(0,0,'array index out of range');
  ArrHeap[aid][idx] := val;
end;

function ToStringV(const v: TValue): string;
begin
  case v.k of
    vkInt: Result := IntToStr(v.i);
    vkStr:
      begin
        if (v.sid >= 0) and (v.sid <= High(StrHeap)) then Result := StrHeap[v.sid]
        else Result := '';
      end;
    vkArr: Result := '[arr:' + IntToStr(ArrLen(v.aid)) + ']';
  end;
end;

function Truthy(const v: TValue): boolean;
begin
  case v.k of
    vkInt: Result := v.i <> 0;
    vkStr: Result := (v.sid >=0) and (v.sid <= High(StrHeap)) and (Length(StrHeap[v.sid]) <> 0);
    vkArr: Result := ArrLen(v.aid) <> 0;
  end;
end;

// ---- VM ----
procedure RunVM;
var
  ip: integer;
  sp: integer;
  stack: TValueArray;

  procedure EnsureCap;
  begin
    if sp >= Length(stack)-1 then
    begin
      if Length(stack)=0 then SetLength(stack, 1024)
      else SetLength(stack, Length(stack)*2);
    end;
  end;

  procedure PushV(const v: TValue);
  begin
    EnsureCap; Inc(sp); stack[sp] := v;
  end;

  procedure PushI(x: Int64); begin PushV(VInt(x)); end;
  procedure PushS(id: integer); begin PushV(VStr(id)); end;
  procedure PushA(id: integer); begin PushV(VArr(id)); end;

  function PopV: TValue;
  begin
    if sp < 0 then ErrorAt(0,0,'VM stack underflow');
    Result := stack[sp]; Dec(sp);
  end;

  function PopI: Int64;
  var v: TValue;
  begin
    v := PopV;
    if v.k <> vkInt then ErrorAt(0,0,'expected int');
    Result := v.i;
  end;

  function PopArr: integer;
  var v: TValue;
  begin
    v := PopV;
    if v.k <> vkArr then ErrorAt(0,0,'expected array');
    Result := v.aid;
  end;

var
  a,b: TValue; s: string; tgt: integer; fidx, argc, nlocals: integer;
  bp: integer; // base pointer into stack (params start)
  retIPStack: array of integer;
  bpStack: array of integer;
  rsp: integer;
  retToIP, oldbp: integer;
  f: TFunctionInfo;
  ofs: integer;
  ia, ib: Int64;  // temps for bit/shift ops

  procedure pushRet(ipv: integer);
  begin
    Inc(rsp);
    if rsp >= Length(retIPStack) then
    begin
      if Length(retIPStack)=0 then
      begin SetLength(retIPStack, 64); SetLength(bpStack, 64); end
      else
      begin SetLength(retIPStack, Length(retIPStack)*2); SetLength(bpStack, Length(bpStack)*2); end;
    end;
    retIPStack[rsp] := ipv;
    bpStack[rsp] := bp;
  end;

  procedure popRet(out ipv: integer; out oldbp: integer);
  begin
    if rsp < 0 then ErrorAt(0,0,'VM call stack underflow');
    ipv := retIPStack[rsp];
    oldbp := bpStack[rsp];
    Dec(rsp);
  end;

begin
  SetLength(stack, 1024); sp := -1;
  SetLength(retIPStack, 64); SetLength(bpStack, 64); rsp := -1;
  bp := 0; ip := BootIP;

  while true do
  begin
    if (ip < 0) or (ip >= Length(Code)) then ErrorAt(0,0,'VM ip out of range');
    case Code[ip] of
      OP_HALT: begin Inc(ip); break; end;

      OP_ICONST: begin Inc(ip); PushI(Code[ip]); Inc(ip); end;
      OP_SCONST: begin Inc(ip); PushS(integer(Code[ip])); Inc(ip); end;

      OP_ADD:
        begin
          Inc(ip);
          b := PopV; a := PopV;
          if (a.k = vkStr) or (b.k = vkStr) then
          begin
            s := ToStringV(a) + ToStringV(b);
            PushS(StrAdd(s));
          end
          else
          begin
            if (a.k<>vkInt) or (b.k<>vkInt) then ErrorAt(0,0,'ADD expects ints/strings');
            PushI(a.i + b.i);
          end;
        end;
      OP_SUB: begin Inc(ip); b:=PopV; a:=PopV; if (a.k<>vkInt) or (b.k<>vkInt) then ErrorAt(0,0,'SUB expects ints'); PushI(a.i - b.i); end;
      OP_MUL: begin Inc(ip); b:=PopV; a:=PopV; if (a.k<>vkInt) or (b.k<>vkInt) then ErrorAt(0,0,'MUL expects ints'); PushI(a.i * b.i); end;
      OP_DIV: begin Inc(ip); b:=PopV; a:=PopV; if (a.k<>vkInt) or (b.k<>vkInt) then ErrorAt(0,0,'DIV expects ints'); if b.i=0 then ErrorAt(0,0,'Division by zero'); PushI(a.i div b.i); end;
      OP_MOD: begin Inc(ip); b:=PopV; a:=PopV; if (a.k<>vkInt) or (b.k<>vkInt) then ErrorAt(0,0,'MOD expects ints'); if b.i=0 then ErrorAt(0,0,'Modulo by zero'); PushI(a.i mod b.i); end;

      OP_NEG: begin Inc(ip); a:=PopV; if a.k<>vkInt then ErrorAt(0,0,'NEG expects int'); PushI(-a.i); end;
      OP_NOT: begin Inc(ip); a:=PopV; if a.k<>vkInt then ErrorAt(0,0,'NOT expects int'); if a.i=0 then PushI(1) else PushI(0); end;

      OP_EQ:
        begin Inc(ip); b:=PopV; a:=PopV;
          if (a.k=vkInt) and (b.k=vkInt) then PushI(Ord(a.i=b.i))
          else PushI(Ord(ToStringV(a)=ToStringV(b)));
        end;
      OP_NE:
        begin Inc(ip); b:=PopV; a:=PopV;
          if (a.k=vkInt) and (b.k=vkInt) then PushI(Ord(a.i<>b.i))
          else PushI(Ord(ToStringV(a)<>ToStringV(b)));
        end;
      OP_LT: begin Inc(ip); b:=PopV; a:=PopV; if (a.k<>vkInt) or (b.k<>vkInt) then ErrorAt(0,0,'LT expects ints'); PushI(Ord(a.i<b.i)); end;
      OP_LE: begin Inc(ip); b:=PopV; a:=PopV; if (a.k<>vkInt) or (b.k<>vkInt) then ErrorAt(0,0,'LE expects ints'); PushI(Ord(a.i<=b.i)); end;
      OP_GT: begin Inc(ip); b:=PopV; a:=PopV; if (a.k<>vkInt) or (b.k<>vkInt) then ErrorAt(0,0,'GT expects ints'); PushI(Ord(a.i>b.i)); end;
      OP_GE: begin Inc(ip); b:=PopV; a:=PopV; if (a.k<>vkInt) or (b.k<>vkInt) then ErrorAt(0,0,'GE expects ints'); PushI(Ord(a.i>=b.i)); end;

      OP_BAND: begin Inc(ip); ib := PopI; ia := PopI; PushI(ia and ib); end;
      OP_BOR:  begin Inc(ip); ib := PopI; ia := PopI; PushI(ia or  ib); end;
      OP_BXOR: begin Inc(ip); ib := PopI; ia := PopI; PushI(ia xor ib); end;
      OP_BNOT: begin Inc(ip); ia := PopI; PushI(not ia); end;
      OP_SHL:  begin Inc(ip); ib := PopI; ia := PopI; if ib < 0 then ErrorAt(0,0,'negative shift'); PushI(ia shl ib); end;
      OP_SHR:  begin Inc(ip); ib := PopI; ia := PopI; if ib < 0 then ErrorAt(0,0,'negative shift'); PushI(ia shr ib); end;

      OP_LAND: begin Inc(ip); b:=PopV; a:=PopV; PushI(Ord(Truthy(a) and Truthy(b))); end;
      OP_LOR:  begin Inc(ip); b:=PopV; a:=PopV; PushI(Ord(Truthy(a) or  Truthy(b))); end;

      OP_JMP: begin Inc(ip); tgt := integer(Code[ip]); ip := tgt; end;
      OP_JZ:
        begin
          Inc(ip); tgt := integer(Code[ip]); Inc(ip);
          a := PopV; if not Truthy(a) then ip := tgt;
        end;

      OP_LOAD:
        begin
          Inc(ip); ofs := integer(Code[ip]); Inc(ip);
          PushV(stack[bp + ofs]);
        end;
      OP_STORE:
        begin
          Inc(ip); ofs := integer(Code[ip]); Inc(ip);
          a:=PopV; stack[bp + ofs] := a;
        end;

      OP_CALL:
        begin
          Inc(ip); fidx := integer(Code[ip]); argc := integer(Code[ip+1]); Inc(ip,2);
          if (fidx < 0) or (fidx > High(Funcs)) then ErrorAt(0,0,'Bad function index');
          f := Funcs[fidx];
          // push return frame
          pushRet(ip);
          // params already on stack; new bp is first arg
          bp := sp - argc + 1;
          ip := f.addr;
        end;

      OP_RET:
        begin
          Inc(ip);
          a := PopV; // return value
          popRet(retToIP, oldbp);
          sp := bp - 1; // drop params + locals
          bp := oldbp;
          ip := retToIP;
          PushV(a);
        end;

      OP_PRINT:
        begin
          Inc(ip);
          a := PopV;
          if a.k = vkStr then Writeln(ToStringV(a))
          else if a.k = vkInt then Writeln(a.i)
          else Writeln(ToStringV(a)); // array prints [arr:n]
        end;

      OP_POP: begin Inc(ip); PopV; end;

      OP_ENTER:
        begin
          Inc(ip); nlocals := integer(Code[ip]); Inc(ip);
          while nlocals > 0 do begin PushI(0); Dec(nlocals); end;
        end;

      OP_ANEW: begin Inc(ip); PushA(ArrNew(integer(PopI))); end;
      OP_AGET: begin Inc(ip); tgt := integer(PopI); fidx := PopArr; PushI(ArrGet(fidx, tgt)); end;
      OP_ASET: begin Inc(ip); b := PopV; if b.k<>vkInt then ErrorAt(0,0,'array stores ints'); tgt := integer(PopI); fidx := PopArr; ArrSet(fidx, tgt, b.i); end;
      OP_LEN:
        begin
          Inc(ip); a := PopV;
          case a.k of
            vkStr: PushI(Length(ToStringV(a)));
            vkArr: PushI(ArrLen(a.aid));
            vkInt: PushI(0);
          end;
        end;

    else
      ErrorAt(0,0,'Unknown opcode: ' + IntToStr(Code[ip]));
    end;
  end;
end;

// ---- File + Driver ----
function ReadAllText(const path: string): string;
var fs: TFileStream; ss: TStringStream;
begin
  fs := TFileStream.Create(path, fmOpenRead or fmShareDenyNone);
  try
    ss := TStringStream.Create('');
    try
      ss.CopyFrom(fs, fs.Size);
      Result := ss.DataString;
    finally ss.Free; end;
  finally fs.Free; end;
end;

procedure Usage;
begin
  Writeln('Quokka (arrays+strings+bitops) — compiler+VM');
  Writeln('Usage:  ./compiler [--dump] <file.qk>');
  Halt(1);
end;

var
  srcPath: string;

begin
  if ParamCount < 1 then Usage;

  OptDumpOnly := false;
  if (ParamStr(1) = '--dump') then
  begin
    if ParamCount < 2 then Usage;
    OptDumpOnly := true;
    srcPath := ParamStr(2);
  end
  else
    srcPath := ParamStr(1);

  Source := ReadAllText(srcPath);
  SLen := Length(Source);
  SPos := 1; SLine := 1; SCol := 1;

  SetLength(Code, 0);
  SetLength(Funcs, 0);
  SetLength(StrHeap, 0);
  SetLength(ArrHeap, 0);

  NextToken;
  ParseProgram;

  if OptDumpOnly then DumpCode
  else RunVM;
end.

