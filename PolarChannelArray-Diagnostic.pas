{*******************************************************************************
  PolarChannelArray-Diagnostic.pas
  Altium DelphiScript -- READ-ONLY diagnostic companion to PolarChannelArray.pas

  PURPOSE
    Compute everything v15.2 of PolarChannelArray.pas would compute --
    channel detection, bbox measurement, suffix derivation, polar transform
    plan -- and dump it to a plain-text file WITHOUT moving any primitive.

  ENTRY POINT
    EmitPolarArrayDiagnostic

  OUTPUT
    C:\Users\Public\PolarChannelArray-diag.txt
    Written via TStringList.SaveToFile. Created/overwritten on each run.

  INVOCATION
    Inside Altium: File > Run Script > Browse to this .pas, select
    EmitPolarArrayDiagnostic from the procedure list, click Run.
    Or add it to a .PrjScr project and invoke from the Scripts panel.

  INPUTS
    Same interactive prompts as PolarChannelArray.pas v15.2:
      1. Pre-select a component in the reference channel OR click when prompted.
      2. Click or type the polar origin.

  WHAT THIS EMITS (file sections)
    [HEADER]     Date/time, board name, total component-class count.
    [USER_INPUT] Reference component, reference class, derived prefix, origin.
    [CHANNEL i]  Per-channel block: class, suffix, comp count, pre-script
                 bbox, first 3 comps, first 5 free primitives in bbox.
    [PLAN]       For each non-ref channel i=1..N-1:
                   rotateDeg, predicted newCX/newCY,
                   first 3 comps predicted positions (v15 formula),
                   first 3 tracks predicted endpoint positions
                     (v15 formula: pivot=preC, destination=newC),
                   same 3 tracks under ALTERNATIVE formula
                     (rotate around polarO directly).
    [DONE]       Closing line with file path.

  AD26 HARD RULES RESPECTED
    - No nested brace comments (no literal braces inside comment bodies).
    - No AssignFile / TextFile / Writeln -- TStringList.SaveToFile only.
    - No Comp.GroupId.
    - Output path under C:\Users\Public\ for Windows permissions.
    - Board.SelectecObject wrapped in try/except for the known typo/version risk.
    - Brace depth: max 1, final 0 (verified before ship).

  PATTERNS PORTED FROM PolarChannelArray.pas v15.2 (d7df0c5)
    RotatePointXY, PointInRect, PrimitiveKey, IsBuiltInComponentClass,
    FindClassByName, CountClassMembers, ComputeChannelBBox,
    ComputeMargin, CollectMatchingClasses, SnapSuffixToUnderscore,
    DeriveClassSuffix, StripChannelSuffix, FindMatchingComponent,
    FindChannelClassForComponent, DerivePrefixFromReference,
    FindSelectedComponent, FindComponentAtLocation,
    SnapshotChannelBBoxes, GetBBoxFromSnapshot.
    All port verbatim or near-verbatim; divergence noted inline.

  AUTHOR
    Forman (production-agents altium-script-author sub-agent), 2026-05-15.
    Based entirely on PolarChannelArray.pas v15.2 by Cimos/CubePilot.
*******************************************************************************}

const
  DEG_TO_RAD_D           = 0.017453292519943;
  MAX_CHANNELS_SAFETY_D  = 256;
  COMP_CLASS_MEMBER_KIND_D = 1;
  MARGIN_FRACTION_D      = 0.25;
  MARGIN_MIN_MM_D        = 5.0;
  MARGIN_MAX_MM_D        = 50.0;

  DIAG_OUT_PATH = 'C:\Users\Public\PolarChannelArray-diag.txt';

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:248 -- RotatePointXY verbatim }
procedure D_RotatePointXY(ix, iy     : TCoord;
                          cx, cy     : TCoord;
                          angleDeg   : Double;
                          var ox, oy : TCoord);
var
  rad, cosA, sinA, dx, dy : Double;
begin
  rad  := angleDeg * DEG_TO_RAD_D;
  cosA := Cos(rad);
  sinA := Sin(rad);
  dx   := CoordToMMs(ix - cx);
  dy   := CoordToMMs(iy - cy);
  ox   := cx + MMsToCoord(dx * cosA - dy * sinA);
  oy   := cy + MMsToCoord(dx * sinA + dy * cosA);
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:273 -- PointInRect verbatim }
function D_PointInRect(x, y, x1, y1, x2, y2 : TCoord) : Boolean;
begin
  Result := (x >= x1) and (x <= x2) and (y >= y1) and (y <= y2);
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:279 -- PrimitiveKey verbatim }
function D_PrimitiveKey(Prim : IPCB_Primitive) : String;
begin
  Result := '?';
  case Prim.ObjectId of
    eTrackObject:
      Result := 'T:' + IntToStr(Prim.Layer) + ',' +
                IntToStr(Prim.X1) + ',' + IntToStr(Prim.Y1) + ',' +
                IntToStr(Prim.X2) + ',' + IntToStr(Prim.Y2);
    eViaObject:
      Result := 'V:' + IntToStr(Prim.Layer) + ',' +
                IntToStr(Prim.X) + ',' + IntToStr(Prim.Y);
    eArcObject:
      Result := 'A:' + IntToStr(Prim.Layer) + ',' +
                IntToStr(Prim.XCenter) + ',' + IntToStr(Prim.YCenter);
    eFillObject:
      Result := 'F:' + IntToStr(Prim.Layer) + ',' +
                IntToStr(Prim.X1Location) + ',' + IntToStr(Prim.Y1Location) + ',' +
                IntToStr(Prim.X2Location) + ',' + IntToStr(Prim.Y2Location);
    eTextObject:
      Result := 'X:' + IntToStr(Prim.Layer) + ',' +
                IntToStr(Prim.XLocation) + ',' + IntToStr(Prim.YLocation);
    ePadObject:
      Result := 'P:' + IntToStr(Prim.Layer) + ',' +
                IntToStr(Prim.X) + ',' + IntToStr(Prim.Y);
  end;
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:321 -- IsBuiltInComponentClass verbatim }
function D_IsBuiltInComponentClass(Cls : IPCB_ObjectClass) : Boolean;
var
  nm      : String;
  isSuper : Boolean;
begin
  isSuper := False;
  try
    isSuper := Cls.SuperClass;
  except
    isSuper := False;
  end;
  if isSuper then
  begin
    Result := True;
    Exit;
  end;

  nm := Cls.Name;
  Result := (CompareText(nm, 'All Components') = 0) or
            (CompareText(nm, 'Inside Board Components') = 0) or
            (CompareText(nm, 'Outside Board Components') = 0) or
            (CompareText(nm, 'Top Side Components') = 0) or
            (CompareText(nm, 'Bottom Side Components') = 0);
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:347 -- FindClassByName verbatim }
function D_FindClassByName(Board : IPCB_Board; name : String) : IPCB_ObjectClass;
var
  Iter : IPCB_BoardIterator;
  Prim : IPCB_Primitive;
  Cls  : IPCB_ObjectClass;
begin
  Result := Nil;
  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eClassObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    Cls := Prim;
    if (Cls.MemberKind = COMP_CLASS_MEMBER_KIND_D) and (Cls.Name = name) then
    begin
      Result := Cls;
      Break;
    end;
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:377 -- CountClassMembers verbatim }
function D_CountClassMembers(Board : IPCB_Board; Cls : IPCB_ObjectClass) : Integer;
var
  Iter : IPCB_BoardIterator;
  Comp : IPCB_Component;
begin
  Result := 0;
  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);
  Comp := Iter.FirstPCBObject;
  while Comp <> Nil do
  begin
    if Cls.IsMember(Comp) then
      Result := Result + 1;
    Comp := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:398 -- ComputeChannelBBox verbatim }
procedure D_ComputeChannelBBox(Board : IPCB_Board;
                               Cls   : IPCB_ObjectClass;
                               var minX, minY, maxX, maxY : TCoord;
                               var count : Integer);
var
  Iter         : IPCB_BoardIterator;
  Comp         : IPCB_Component;
  L, B, R, T_  : TCoord;
begin
  count := 0;
  minX := 0; minY := 0; maxX := 0; maxY := 0;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Comp := Iter.FirstPCBObject;
  while Comp <> Nil do
  begin
    if Cls.IsMember(Comp) then
    begin
      L  := Comp.BoundingRectangle.Left;
      B  := Comp.BoundingRectangle.Bottom;
      R  := Comp.BoundingRectangle.Right;
      T_ := Comp.BoundingRectangle.Top;

      if count = 0 then
      begin
        minX := L; minY := B; maxX := R; maxY := T_;
      end
      else
      begin
        if L  < minX then minX := L;
        if B  < minY then minY := B;
        if R  > maxX then maxX := R;
        if T_ > maxY then maxY := T_;
      end;
      count := count + 1;
    end;
    Comp := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:661 -- ComputeMargin verbatim }
function D_ComputeMargin(bx1, by1, bx2, by2 : TCoord) : TCoord;
var
  w_mm, h_mm, big_mm, marg_mm : Double;
begin
  w_mm := CoordToMMs(bx2 - bx1);
  h_mm := CoordToMMs(by2 - by1);
  if w_mm > h_mm then big_mm := w_mm else big_mm := h_mm;
  marg_mm := big_mm * MARGIN_FRACTION_D;
  if marg_mm < MARGIN_MIN_MM_D then marg_mm := MARGIN_MIN_MM_D;
  if marg_mm > MARGIN_MAX_MM_D then marg_mm := MARGIN_MAX_MM_D;
  Result := MMsToCoord(marg_mm);
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:678 -- CollectMatchingClasses verbatim }
procedure D_CollectMatchingClasses(Board     : IPCB_Board;
                                   prefix    : String;
                                   ChanNames : TStringList);
var
  Iter : IPCB_BoardIterator;
  Prim : IPCB_Primitive;
  Cls  : IPCB_ObjectClass;
begin
  ChanNames.Clear;
  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eClassObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    Cls := Prim;
    if (Cls.MemberKind = COMP_CLASS_MEMBER_KIND_D) and
       (not D_IsBuiltInComponentClass(Cls)) and
       (AnsiUpperCase(Copy(Cls.Name, 1, Length(prefix))) =
        AnsiUpperCase(prefix)) and
       (D_CountClassMembers(Board, Cls) > 0) then
    begin
      if ChanNames.Count < MAX_CHANNELS_SAFETY_D then
        ChanNames.Add(Cls.Name);
    end;
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:720 -- SnapSuffixToUnderscore verbatim }
function D_SnapSuffixToUnderscore(suffix : String) : String;
var
  i, l : Integer;
begin
  Result := '';
  l := Length(suffix);
  for i := 1 to l do
  begin
    if Copy(suffix, i, 1) = '_' then
    begin
      Result := Copy(suffix, i, l - i + 1);
      Exit;
    end;
  end;
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:759 -- DeriveClassSuffix verbatim }
function D_DeriveClassSuffix(Board : IPCB_Board; Cls : IPCB_ObjectClass) : String;
var
  Iter             : IPCB_BoardIterator;
  Comp             : IPCB_Component;
  firstDesig       : String;
  currentDesig     : String;
  haveFirst        : Boolean;
  observedMultiple : Boolean;
  commonLen        : Integer;
  l1, l2, minL, matchLen, i : Integer;
begin
  Result := '';
  firstDesig := '';
  haveFirst := False;
  observedMultiple := False;
  commonLen := 0;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Comp := Iter.FirstPCBObject;
  while Comp <> Nil do
  begin
    if Cls.IsMember(Comp) then
    begin
      currentDesig := Comp.Name.Text;
      if not haveFirst then
      begin
        firstDesig := currentDesig;
        commonLen := Length(firstDesig);
        haveFirst := True;
      end
      else
      begin
        observedMultiple := True;
        l1 := Length(firstDesig);
        l2 := Length(currentDesig);
        if l1 < l2 then minL := l1 else minL := l2;
        matchLen := 0;
        for i := 0 to minL - 1 do
        begin
          if AnsiUpperCase(Copy(firstDesig, l1 - i, 1)) =
             AnsiUpperCase(Copy(currentDesig, l2 - i, 1)) then
            matchLen := matchLen + 1
          else
            Break;
        end;
        if matchLen < commonLen then commonLen := matchLen;
      end;
    end;
    Comp := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  if haveFirst and observedMultiple and (commonLen > 0) then
    Result := D_SnapSuffixToUnderscore(
                Copy(firstDesig, Length(firstDesig) - commonLen + 1, commonLen));
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:839 -- StripChannelSuffix verbatim }
function D_StripChannelSuffix(designator, classSuffix : String) : String;
var
  desigLen, suffLen : Integer;
begin
  if classSuffix = '' then
  begin
    Result := designator;
    Exit;
  end;
  desigLen := Length(designator);
  suffLen  := Length(classSuffix);
  if (desigLen >= suffLen) and
     (AnsiUpperCase(Copy(designator, desigLen - suffLen + 1, suffLen)) =
      AnsiUpperCase(classSuffix)) then
    Result := Copy(designator, 1, desigLen - suffLen)
  else
    Result := designator;
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:1105 -- FindChannelClassForComponent verbatim }
function D_FindChannelClassForComponent(Board : IPCB_Board;
                                        Comp  : IPCB_Component) : String;
var
  Iter         : IPCB_BoardIterator;
  Prim         : IPCB_Primitive;
  Cls          : IPCB_ObjectClass;
  longestMatch : String;
begin
  longestMatch := '';

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eClassObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    Cls := Prim;
    if (Cls.MemberKind = COMP_CLASS_MEMBER_KIND_D) and
       (not D_IsBuiltInComponentClass(Cls)) and
       Cls.IsMember(Comp) then
    begin
      if Length(Cls.Name) > Length(longestMatch) then
        longestMatch := Cls.Name;
    end;
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
  Result := longestMatch;
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:1145 -- DerivePrefixFromReference verbatim }
function D_DerivePrefixFromReference(Board   : IPCB_Board;
                                     refName : String) : String;
var
  Iter       : IPCB_BoardIterator;
  Prim       : IPCB_Primitive;
  Cls        : IPCB_ObjectClass;
  AllClasses : TStringList;
  i, k       : Integer;
  cand       : String;
  found      : Boolean;
begin
  Result := '';
  AllClasses := TStringList.Create;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eClassObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    Cls := Prim;
    if (Cls.MemberKind = COMP_CLASS_MEMBER_KIND_D) and
       (not D_IsBuiltInComponentClass(Cls)) and
       (AnsiUpperCase(Cls.Name) <> AnsiUpperCase(refName)) and
       (D_CountClassMembers(Board, Cls) > 0) then
      AllClasses.Add(Cls.Name);
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  for k := Length(refName) - 1 downto 1 do
  begin
    cand := Copy(refName, 1, k);
    found := False;
    for i := 0 to AllClasses.Count - 1 do
    begin
      if AnsiUpperCase(Copy(AllClasses[i], 1, k)) = AnsiUpperCase(cand) then
      begin
        found := True;
        Break;
      end;
    end;
    if found then
    begin
      Result := cand;
      Break;
    end;
  end;

  AllClasses.Free;
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:1010 -- FindSelectedComponent verbatim }
function D_FindSelectedComponent(Board : IPCB_Board) : IPCB_Component;
var
  i, n         : Integer;
  Prim         : IPCB_Primitive;
  fallbackComp : IPCB_Component;
begin
  Result := Nil;
  fallbackComp := Nil;

  try
    n := Board.SelectecObjectCount;
  except
    n := 0;
  end;

  for i := 0 to n - 1 do
  begin
    Prim := Nil;
    try
      Prim := Board.SelectecObject[i];
    except
      Prim := Nil;
    end;
    if Prim = Nil then Continue;

    if Prim.ObjectId = eComponentObject then
    begin
      Result := Prim;
      Exit;
    end;

    if (fallbackComp = Nil) and (Prim.Component <> Nil) then
      fallbackComp := Prim.Component;
  end;

  Result := fallbackComp;
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:1054 -- FindComponentAtLocation verbatim }
function D_FindComponentAtLocation(Board : IPCB_Board;
                                   X     : TCoord;
                                   Y     : TCoord) : IPCB_Component;
var
  Iter     : IPCB_BoardIterator;
  Comp     : IPCB_Component;
  bestComp : IPCB_Component;
  bestDist : Double;
  dist     : Double;
begin
  bestComp := Nil;
  bestDist := 1e30;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Comp := Iter.FirstPCBObject;
  while Comp <> Nil do
  begin
    if (X >= Comp.BoundingRectangle.Left)   and
       (X <= Comp.BoundingRectangle.Right)  and
       (Y >= Comp.BoundingRectangle.Bottom) and
       (Y <= Comp.BoundingRectangle.Top) then
    begin
      bestComp := Comp;
      bestDist := -1;
      Break;
    end;
    dist := Sqrt(Sqr(CoordToMMs(Comp.X - X)) + Sqr(CoordToMMs(Comp.Y - Y)));
    if dist < bestDist then
    begin
      bestComp := Comp;
      bestDist := dist;
    end;
    Comp := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
  Result := bestComp;
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:1215 -- SnapshotChannelBBoxes verbatim }
procedure D_SnapshotChannelBBoxes(Board     : IPCB_Board;
                                  ChanNames : TStringList;
                                  BBoxes    : TStringList);
var
  i, compCount              : Integer;
  minX, minY, maxX, maxY   : TCoord;
  cx, cy                    : TCoord;
  Cls                       : IPCB_ObjectClass;
  csv                       : String;
begin
  BBoxes.Clear;
  for i := 0 to ChanNames.Count - 1 do
  begin
    Cls := D_FindClassByName(Board, ChanNames[i]);
    if Cls = Nil then
    begin
      BBoxes.Add('0,0,0,0,0,0,0');
      Continue;
    end;
    D_ComputeChannelBBox(Board, Cls, minX, minY, maxX, maxY, compCount);
    cx := (minX + maxX) div 2;
    cy := (minY + maxY) div 2;
    csv := IntToStr(minX) + ',' + IntToStr(minY) + ',' +
           IntToStr(maxX) + ',' + IntToStr(maxY) + ',' +
           IntToStr(cx)   + ',' + IntToStr(cy)   + ',' +
           IntToStr(compCount);
    BBoxes.Add(csv);
  end;
end;

{ --------------------------------------------------------------------------- }
{ pattern from PolarChannelArray.pas:1257 -- GetBBoxFromSnapshot verbatim }
procedure D_GetBBoxFromSnapshot(BBoxes : TStringList;
                                idx    : Integer;
                                var minX, minY, maxX, maxY, cx, cy : TCoord;
                                var compCount : Integer);
var
  csv, token  : String;
  p, fieldIdx : Integer;
  vals        : array[0..6] of Integer;
begin
  minX := 0; minY := 0; maxX := 0; maxY := 0;
  cx   := 0; cy   := 0; compCount := 0;

  if (idx < 0) or (idx >= BBoxes.Count) then Exit;

  for fieldIdx := 0 to 6 do vals[fieldIdx] := 0;

  csv := BBoxes[idx];
  fieldIdx := 0;

  while (Length(csv) > 0) and (fieldIdx < 7) do
  begin
    p := Pos(',', csv);
    if p = 0 then
    begin
      token := csv;
      csv := '';
    end
    else
    begin
      token := Copy(csv, 1, p - 1);
      csv := Copy(csv, p + 1, Length(csv) - p);
    end;
    vals[fieldIdx] := StrToIntDef(Trim(token), 0);
    fieldIdx := fieldIdx + 1;
  end;

  if fieldIdx < 7 then Exit;

  minX      := vals[0];
  minY      := vals[1];
  maxX      := vals[2];
  maxY      := vals[3];
  cx        := vals[4];
  cy        := vals[5];
  compCount := vals[6];
end;

{ ---------------------------------------------------------------------------
  D_Fmt -- format a TCoord value as a mm string with 4 decimal places.
  Diagnostic output helper.
--------------------------------------------------------------------------- }
function D_Fmt(c : TCoord) : String;
begin
  Result := FloatToStrF(CoordToMMs(c), ffFixed, 12, 4);
end;

{ ---------------------------------------------------------------------------
  D_FmtDeg -- format a Double angle to 4 decimal places.
--------------------------------------------------------------------------- }
function D_FmtDeg(d : Double) : String;
begin
  Result := FloatToStrF(d, ffFixed, 10, 4);
end;

{ ---------------------------------------------------------------------------
  D_LayerName -- return a human-readable layer name for diagnostic output.
  Falls back to the integer string if the board API call raises.
--------------------------------------------------------------------------- }
function D_LayerName(Board : IPCB_Board; layer : Integer) : String;
begin
  Result := IntToStr(layer);
  try
    Result := Board.LayerName(layer);
  except
  end;
end;

{ ---------------------------------------------------------------------------
  D_ClassCount -- count user-defined (non-built-in) component classes on
  the board with at least one member.
--------------------------------------------------------------------------- }
function D_ClassCount(Board : IPCB_Board) : Integer;
var
  Iter : IPCB_BoardIterator;
  Prim : IPCB_Primitive;
  Cls  : IPCB_ObjectClass;
begin
  Result := 0;
  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eClassObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);
  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    Cls := Prim;
    if (Cls.MemberKind = COMP_CLASS_MEMBER_KIND_D) and
       (not D_IsBuiltInComponentClass(Cls)) and
       (D_CountClassMembers(Board, Cls) > 0) then
      Result := Result + 1;
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ ---------------------------------------------------------------------------
  D_EmitChannelComponents
  Write the first up to maxComps components in the class to Lines.
  One line per component: designator, X mm, Y mm, rotation deg, layer.
--------------------------------------------------------------------------- }
procedure D_EmitChannelComponents(Board   : IPCB_Board;
                                  Lines   : TStringList;
                                  Cls     : IPCB_ObjectClass;
                                  maxComps : Integer;
                                  indent  : String);
var
  Iter     : IPCB_BoardIterator;
  Comp     : IPCB_Component;
  emitted  : Integer;
  layName  : String;
begin
  emitted := 0;
  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);
  Comp := Iter.FirstPCBObject;
  while (Comp <> Nil) and (emitted < maxComps) do
  begin
    if Cls.IsMember(Comp) then
    begin
      layName := D_LayerName(Board, Comp.Layer);
      Lines.Add(indent + 'COMP  desig=' + Comp.Name.Text +
                '  X=' + D_Fmt(Comp.X) + 'mm' +
                '  Y=' + D_Fmt(Comp.Y) + 'mm' +
                '  rot=' + D_FmtDeg(Comp.Rotation) + 'deg' +
                '  layer=' + layName);
      emitted := emitted + 1;
    end;
    Comp := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
  if emitted = 0 then
    Lines.Add(indent + '(no components found)');
end;

{ ---------------------------------------------------------------------------
  D_EmitFreePrimitives
  Emit up to maxPrims free primitives whose centroid falls inside
  (bx1-margin .. bx2+margin, by1-margin .. by2+margin).
  Uses a spatial iterator just like v15.2; no mutations.
--------------------------------------------------------------------------- }
procedure D_EmitFreePrimitives(Board    : IPCB_Board;
                               Lines    : TStringList;
                               bx1, by1, bx2, by2 : TCoord;
                               margin   : TCoord;
                               maxPrims : Integer;
                               indent   : String);
var
  Iter    : IPCB_SpatialIterator;
  Prim    : IPCB_Primitive;
  emitted : Integer;
  midX, midY, fillCX, fillCY : TCoord;
  layerStr : String;
  track   : IPCB_Track;
  via     : IPCB_Via;
  arc     : IPCB_Arc;
  txt     : IPCB_Text;
  pad     : IPCB_Pad;
begin
  emitted := 0;

  Iter := Board.SpatialIterator_Create;
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Area(bx1 - margin, by1 - margin,
                      bx2 + margin, by2 + margin);

  Prim := Iter.FirstPCBObject;
  while (Prim <> Nil) and (emitted < maxPrims) do
  begin
    case Prim.ObjectId of

      eTrackObject:
      begin
        track := Prim;
        if track.Component = Nil then
        begin
          midX := (track.X1 + track.X2) div 2;
          midY := (track.Y1 + track.Y2) div 2;
          if D_PointInRect(midX, midY,
                           bx1 - margin, by1 - margin,
                           bx2 + margin, by2 + margin) then
          begin
            layerStr := D_LayerName(Board, track.Layer);
            Lines.Add(indent + 'PRIM  kind=TRACK' +
                      '  layer=' + layerStr +
                      '  X1=' + D_Fmt(track.X1) + 'mm' +
                      '  Y1=' + D_Fmt(track.Y1) + 'mm' +
                      '  X2=' + D_Fmt(track.X2) + 'mm' +
                      '  Y2=' + D_Fmt(track.Y2) + 'mm' +
                      '  midX=' + D_Fmt(midX) + 'mm' +
                      '  midY=' + D_Fmt(midY) + 'mm');
            emitted := emitted + 1;
          end;
        end;
      end;

      eViaObject:
      begin
        via := Prim;
        if via.Component = Nil then
        begin
          if D_PointInRect(via.X, via.Y,
                           bx1 - margin, by1 - margin,
                           bx2 + margin, by2 + margin) then
          begin
            Lines.Add(indent + 'PRIM  kind=VIA' +
                      '  layer=MULTI' +
                      '  X=' + D_Fmt(via.X) + 'mm' +
                      '  Y=' + D_Fmt(via.Y) + 'mm');
            emitted := emitted + 1;
          end;
        end;
      end;

      eArcObject:
      begin
        arc := Prim;
        if arc.Component = Nil then
        begin
          if D_PointInRect(arc.XCenter, arc.YCenter,
                           bx1 - margin, by1 - margin,
                           bx2 + margin, by2 + margin) then
          begin
            layerStr := D_LayerName(Board, arc.Layer);
            Lines.Add(indent + 'PRIM  kind=ARC' +
                      '  layer=' + layerStr +
                      '  Xctr=' + D_Fmt(arc.XCenter) + 'mm' +
                      '  Yctr=' + D_Fmt(arc.YCenter) + 'mm');
            emitted := emitted + 1;
          end;
        end;
      end;

      eFillObject:
      begin
        if Prim.Component = Nil then
        begin
          fillCX := (Prim.X1Location + Prim.X2Location) div 2;
          fillCY := (Prim.Y1Location + Prim.Y2Location) div 2;
          if D_PointInRect(fillCX, fillCY,
                           bx1 - margin, by1 - margin,
                           bx2 + margin, by2 + margin) then
          begin
            layerStr := D_LayerName(Board, Prim.Layer);
            Lines.Add(indent + 'PRIM  kind=FILL' +
                      '  layer=' + layerStr +
                      '  ctrX=' + D_Fmt(fillCX) + 'mm' +
                      '  ctrY=' + D_Fmt(fillCY) + 'mm' +
                      '  X1=' + D_Fmt(Prim.X1Location) + 'mm' +
                      '  Y1=' + D_Fmt(Prim.Y1Location) + 'mm' +
                      '  X2=' + D_Fmt(Prim.X2Location) + 'mm' +
                      '  Y2=' + D_Fmt(Prim.Y2Location) + 'mm');
            emitted := emitted + 1;
          end;
        end;
      end;

      eTextObject:
      begin
        txt := Prim;
        if txt.Component = Nil then
        begin
          if D_PointInRect(txt.XLocation, txt.YLocation,
                           bx1 - margin, by1 - margin,
                           bx2 + margin, by2 + margin) then
          begin
            layerStr := D_LayerName(Board, txt.Layer);
            Lines.Add(indent + 'PRIM  kind=TEXT' +
                      '  layer=' + layerStr +
                      '  X=' + D_Fmt(txt.XLocation) + 'mm' +
                      '  Y=' + D_Fmt(txt.YLocation) + 'mm' +
                      '  text="' + txt.Text + '"');
            emitted := emitted + 1;
          end;
        end;
      end;

      ePadObject:
      begin
        pad := Prim;
        if pad.Component = Nil then
        begin
          if D_PointInRect(pad.X, pad.Y,
                           bx1 - margin, by1 - margin,
                           bx2 + margin, by2 + margin) then
          begin
            layerStr := D_LayerName(Board, pad.Layer);
            Lines.Add(indent + 'PRIM  kind=FREEPAD' +
                      '  layer=' + layerStr +
                      '  X=' + D_Fmt(pad.X) + 'mm' +
                      '  Y=' + D_Fmt(pad.Y) + 'mm');
            emitted := emitted + 1;
          end;
        end;
      end;

    end;
    Prim := Iter.NextPCBObject;
  end;

  Board.SpatialIterator_Destroy(Iter);

  if emitted = 0 then
    Lines.Add(indent + '(no free primitives in bbox+margin)');
end;

{ ---------------------------------------------------------------------------
  D_CollectFirstTracks
  Collect up to maxTracks free tracks whose midpoint falls inside
  (bx1-margin .. bx2+margin). Returns results as CSV lines in TrackData:
    one line per track: "X1,Y1,X2,Y2" (TCoord integer values).
  Avoids open-array parameters which are unreliable in DelphiScript-on-AD.
--------------------------------------------------------------------------- }
procedure D_CollectFirstTracks(Board    : IPCB_Board;
                               bx1, by1, bx2, by2 : TCoord;
                               margin   : TCoord;
                               maxTracks : Integer;
                               TrackData : TStringList);
var
  Iter       : IPCB_SpatialIterator;
  Prim       : IPCB_Primitive;
  track      : IPCB_Track;
  midX, midY : TCoord;
begin
  TrackData.Clear;

  Iter := Board.SpatialIterator_Create;
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Area(bx1 - margin, by1 - margin,
                      bx2 + margin, by2 + margin);

  Prim := Iter.FirstPCBObject;
  while (Prim <> Nil) and (TrackData.Count < maxTracks) do
  begin
    if Prim.ObjectId = eTrackObject then
    begin
      track := Prim;
      if track.Component = Nil then
      begin
        midX := (track.X1 + track.X2) div 2;
        midY := (track.Y1 + track.Y2) div 2;
        if D_PointInRect(midX, midY,
                         bx1 - margin, by1 - margin,
                         bx2 + margin, by2 + margin) then
        begin
          TrackData.Add(IntToStr(track.X1) + ',' +
                        IntToStr(track.Y1) + ',' +
                        IntToStr(track.X2) + ',' +
                        IntToStr(track.Y2));
        end;
      end;
    end;
    Prim := Iter.NextPCBObject;
  end;

  Board.SpatialIterator_Destroy(Iter);
end;

{ ---------------------------------------------------------------------------
  D_ParseTrackCSV
  Parse one CSV line from D_CollectFirstTracks back into TCoord values.
  CSV format: "X1,Y1,X2,Y2" (4 comma-separated integers).
  Returns False if parsing fails.
--------------------------------------------------------------------------- }
function D_ParseTrackCSV(csv : String;
                         var tX1, tY1, tX2, tY2 : TCoord) : Boolean;
var
  parts : TStringList;
  p     : Integer;
  tok   : String;
  vals  : array[0..3] of Integer;
  fi    : Integer;
  rest  : String;
begin
  Result := False;
  tX1 := 0; tY1 := 0; tX2 := 0; tY2 := 0;
  fi := 0;
  rest := csv;
  while (Length(rest) > 0) and (fi < 4) do
  begin
    p := Pos(',', rest);
    if p = 0 then
    begin
      tok := rest;
      rest := '';
    end
    else
    begin
      tok  := Copy(rest, 1, p - 1);
      rest := Copy(rest, p + 1, Length(rest) - p);
    end;
    vals[fi] := StrToIntDef(Trim(tok), 0);
    fi := fi + 1;
  end;
  if fi < 4 then Exit;
  tX1 := vals[0];
  tY1 := vals[1];
  tX2 := vals[2];
  tY2 := vals[3];
  Result := True;
end;

{ ---------------------------------------------------------------------------
  D_CollectFirstComps
  Collect up to maxC components in Cls. Returns results as CSV lines in
  CompData: one line per comp: "desig,X,Y,Rot" where X/Y are TCoord
  integers and Rot is the rotation as a float string.
  Avoids open-array parameters which are unreliable in DelphiScript-on-AD.
--------------------------------------------------------------------------- }
procedure D_CollectFirstComps(Board   : IPCB_Board;
                              Cls     : IPCB_ObjectClass;
                              maxC    : Integer;
                              CompData : TStringList);
var
  Iter : IPCB_BoardIterator;
  Comp : IPCB_Component;
begin
  CompData.Clear;
  if Cls = Nil then Exit;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);
  Comp := Iter.FirstPCBObject;
  while (Comp <> Nil) and (CompData.Count < maxC) do
  begin
    if Cls.IsMember(Comp) then
    begin
      CompData.Add(Comp.Name.Text + ',' +
                   IntToStr(Comp.X)  + ',' +
                   IntToStr(Comp.Y)  + ',' +
                   FloatToStrF(Comp.Rotation, ffFixed, 12, 6));
    end;
    Comp := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ ---------------------------------------------------------------------------
  D_ParseCompCSV
  Parse one CSV line from D_CollectFirstComps back into typed values.
  CSV format: "desig,X,Y,Rot" -- desig may contain commas (unlikely but
  possible). We parse from the RIGHT (last 3 commas hold X, Y, Rot).
  Returns False if parsing fails.
--------------------------------------------------------------------------- }
function D_ParseCompCSV(csv    : String;
                        var desig : String;
                        var cX, cY : TCoord;
                        var cRot   : Double) : Boolean;
var
  p3, p2, p1, j : Integer;
  tail           : String;
  rotStr         : String;
  xStr, yStr     : String;
begin
  Result := False;
  desig := ''; cX := 0; cY := 0; cRot := 0.0;

  { Find the last comma -- this field is Rot }
  p1 := 0;
  for j := Length(csv) downto 1 do
    if Copy(csv, j, 1) = ',' then begin p1 := j; Break; end;
  if p1 = 0 then Exit;
  rotStr := Copy(csv, p1 + 1, Length(csv) - p1);
  tail   := Copy(csv, 1, p1 - 1);

  { Find the next-to-last comma -- this field is Y }
  p2 := 0;
  for j := Length(tail) downto 1 do
    if Copy(tail, j, 1) = ',' then begin p2 := j; Break; end;
  if p2 = 0 then Exit;
  yStr := Copy(tail, p2 + 1, Length(tail) - p2);
  tail := Copy(tail, 1, p2 - 1);

  { Find the third-from-last comma -- this field is X }
  p3 := 0;
  for j := Length(tail) downto 1 do
    if Copy(tail, j, 1) = ',' then begin p3 := j; Break; end;
  if p3 = 0 then Exit;
  xStr  := Copy(tail, p3 + 1, Length(tail) - p3);
  desig := Copy(tail, 1, p3 - 1);

  cX   := StrToIntDef(Trim(xStr),  0);
  cY   := StrToIntDef(Trim(yStr),  0);
  cRot := StrToFloatDef(Trim(rotStr), 0.0);
  Result := True;
end;

{ ===========================================================================
  ENTRY POINT
=========================================================================== }
procedure EmitPolarArrayDiagnostic;
var
  Board        : IPCB_Board;
  Lines        : TStringList;
  ChanNames    : TStringList;
  PreBBoxes    : TStringList;
  ChanSuffixes : TStringList;
  CompDesigs   : TStringList;

  refComp      : IPCB_Component;
  refX, refY   : TCoord;
  refClassName : String;
  prefix       : String;
  refIdx       : Integer;
  N, i, k      : Integer;
  inputStr     : String;
  cx_mm, cy_mm : Double;
  polarX, polarY : TCoord;

  Cls          : IPCB_ObjectClass;
  compCount    : Integer;
  minX, minY, maxX, maxY : TCoord;
  refCX, refCY : TCoord;
  refR_mm      : Double;
  rotateDeg    : Double;
  angStep      : Double;
  newCX, newCY : TCoord;
  margin       : TCoord;

  preMinX, preMinY, preMaxX, preMaxY : TCoord;
  preCX, preCY                        : TCoord;
  preCount                            : Integer;

  totalClasses : Integer;
  suffix       : String;

  MAX_SAMPLE_COMPS  : Integer;
  MAX_SAMPLE_PRIMS  : Integer;
  MAX_SAMPLE_TRACKS : Integer;

  CompData  : TStringList;
  TrackData : TStringList;

  cDesig    : String;
  cX_, cY_  : TCoord;
  cRot_     : Double;
  tX1_, tY1_, tX2_, tY2_ : TCoord;

  pX, pY, pX2, pY2 : TCoord;
  altX, altY, altX2, altY2 : TCoord;
  predRot : Double;
begin
  MAX_SAMPLE_COMPS  := 3;
  MAX_SAMPLE_PRIMS  := 5;
  MAX_SAMPLE_TRACKS := 3;

  Board := PCBServer.GetCurrentPCBBoard;
  if Board = Nil then
  begin
    ShowMessage('ERROR: No PCB document is currently active.' + #13#10 +
                'Open a .PcbDoc and try again.');
    Exit;
  end;

  Lines := TStringList.Create;
  ChanNames := TStringList.Create;
  PreBBoxes := TStringList.Create;
  ChanSuffixes := TStringList.Create;
  CompDesigs := TStringList.Create;
  CompData := TStringList.Create;
  TrackData := TStringList.Create;

  Lines.Add('=== PolarChannelArray Diagnostic ===');
  Lines.Add('Generated : ' + DateTimeToStr(Now));
  Lines.Add('Board     : ' + Board.FileName);
  totalClasses := D_ClassCount(Board);
  Lines.Add('User component classes (non-built-in, non-empty): ' +
            IntToStr(totalClasses));
  Lines.Add('');

  { ---- Step 1: pick reference component ---- }
  Lines.Add('[USER_INPUT]');
  Lines.Add('  Attempting FindSelectedComponent ...');

  refComp := D_FindSelectedComponent(Board);

  if refComp = Nil then
  begin
    Lines.Add('  No pre-selected component found.');
    Lines.Add('  Prompting user to click reference component ...');
    ShowMessage('DIAGNOSTIC: Click on any COMPONENT in the REFERENCE channel.' + #13#10 +
                'Same prompt as PolarChannelArray.pas -- pick the same component' + #13#10 +
                'you would use for the real run.');
    if not Board.ChooseLocation(refX, refY, 'Click a component in the reference channel') then
    begin
      Lines.Add('  User cancelled reference click. Aborting.');
      Lines.SaveToFile(DIAG_OUT_PATH);
      Lines.Free; ChanNames.Free; PreBBoxes.Free;
      ChanSuffixes.Free; CompDesigs.Free;
      CompData.Free; TrackData.Free;
      ShowMessage('Diagnostic aborted at reference click. Partial file saved to:' + #13#10 + DIAG_OUT_PATH);
      Exit;
    end;
    refComp := D_FindComponentAtLocation(Board, refX, refY);
    if refComp = Nil then
    begin
      Lines.Add('  ERROR: No component found near clicked location.');
      Lines.SaveToFile(DIAG_OUT_PATH);
      Lines.Free; ChanNames.Free; PreBBoxes.Free;
      ChanSuffixes.Free; CompDesigs.Free;
      CompData.Free; TrackData.Free;
      ShowMessage('ERROR: No component near click. Partial file saved to:' + #13#10 + DIAG_OUT_PATH);
      Exit;
    end;
    Lines.Add('  Reference component (via click): ' + refComp.Name.Text);
  end
  else
  begin
    Lines.Add('  Reference component (pre-selected): ' + refComp.Name.Text);
  end;

  refClassName := D_FindChannelClassForComponent(Board, refComp);
  if Trim(refClassName) = '' then
  begin
    Lines.Add('  ERROR: Component has no user-defined channel class. Compiled?');
    Lines.SaveToFile(DIAG_OUT_PATH);
    Lines.Free; ChanNames.Free; PreBBoxes.Free;
    ChanSuffixes.Free; CompDesigs.Free;
    CompData.Free; TrackData.Free;
    ShowMessage('ERROR: No channel class found. Partial file at:' + #13#10 + DIAG_OUT_PATH);
    Exit;
  end;
  Lines.Add('  Reference class    : ' + refClassName);

  prefix := D_DerivePrefixFromReference(Board, refClassName);
  if prefix = '' then
  begin
    Lines.Add('  ERROR: Could not derive channel prefix from "' + refClassName + '".');
    Lines.SaveToFile(DIAG_OUT_PATH);
    Lines.Free; ChanNames.Free; PreBBoxes.Free;
    ChanSuffixes.Free; CompDesigs.Free;
    CompData.Free; TrackData.Free;
    ShowMessage('ERROR: No sibling class shares a prefix. Partial file at:' + #13#10 + DIAG_OUT_PATH);
    Exit;
  end;
  Lines.Add('  Derived prefix     : "' + prefix + '"');

  { ---- Step 2: collect channel classes ---- }
  ChanNames.Sorted := True;
  ChanNames.Duplicates := dupIgnore;
  D_CollectMatchingClasses(Board, prefix, ChanNames);
  N := ChanNames.Count;
  Lines.Add('  Channel count      : ' + IntToStr(N));

  if N < 2 then
  begin
    Lines.Add('  ERROR: Need at least 2 channels. Found: ' + IntToStr(N));
    Lines.SaveToFile(DIAG_OUT_PATH);
    Lines.Free; ChanNames.Free; PreBBoxes.Free;
    ChanSuffixes.Free; CompDesigs.Free;
    CompData.Free; TrackData.Free;
    ShowMessage('ERROR: Fewer than 2 channels. Partial file at:' + #13#10 + DIAG_OUT_PATH);
    Exit;
  end;

  { Move reference class to index 0 }
  refIdx := ChanNames.IndexOf(refClassName);
  if refIdx > 0 then
  begin
    ChanNames.Sorted := False;
    ChanNames.Move(refIdx, 0);
  end;

  Lines.Add('  Channel order (ref first):');
  for i := 0 to N - 1 do
    Lines.Add('    [' + IntToStr(i) + '] ' + ChanNames[i]);
  Lines.Add('');

  { ---- Step 3: pick polar origin ---- }
  if MessageDlg(
       'DIAGNOSTIC: Pick polar origin (same as real run).' + #13#10 +
       'Yes = click on PCB  /  No = type coordinates',
       mtConfirmation, mbYesNo, 0) = mrYes then
  begin
    if not Board.ChooseLocation(polarX, polarY, 'Click the polar origin point') then
    begin
      Lines.Add('[POLAR_ORIGIN] User cancelled origin pick. Aborting.');
      Lines.SaveToFile(DIAG_OUT_PATH);
      Lines.Free; ChanNames.Free; PreBBoxes.Free;
      ChanSuffixes.Free; CompDesigs.Free;
      CompData.Free; TrackData.Free;
      ShowMessage('Diagnostic aborted at origin pick. Partial file at:' + #13#10 + DIAG_OUT_PATH);
      Exit;
    end;
    cx_mm := CoordToMMs(polarX);
    cy_mm := CoordToMMs(polarY);
  end
  else
  begin
    inputStr := InputBox('Diagnostic - Origin', 'Polar origin X (mm):', '0');
    if Trim(inputStr) = '' then
    begin
      Lines.Add('[POLAR_ORIGIN] User cancelled typed origin. Aborting.');
      Lines.SaveToFile(DIAG_OUT_PATH);
      Lines.Free; ChanNames.Free; PreBBoxes.Free;
      ChanSuffixes.Free; CompDesigs.Free;
      CompData.Free; TrackData.Free;
      ShowMessage('Diagnostic aborted. Partial file at:' + #13#10 + DIAG_OUT_PATH);
      Exit;
    end;
    cx_mm := StrToFloatDef(inputStr, 0.0);

    inputStr := InputBox('Diagnostic - Origin', 'Polar origin Y (mm):', '0');
    if Trim(inputStr) = '' then
    begin
      Lines.Add('[POLAR_ORIGIN] User cancelled typed origin. Aborting.');
      Lines.SaveToFile(DIAG_OUT_PATH);
      Lines.Free; ChanNames.Free; PreBBoxes.Free;
      ChanSuffixes.Free; CompDesigs.Free;
      CompData.Free; TrackData.Free;
      ShowMessage('Diagnostic aborted. Partial file at:' + #13#10 + DIAG_OUT_PATH);
      Exit;
    end;
    cy_mm := StrToFloatDef(inputStr, 0.0);
    polarX := MMsToCoord(cx_mm);
    polarY := MMsToCoord(cy_mm);
  end;

  Lines.Add('[POLAR_ORIGIN]');
  Lines.Add('  polarO_X = ' + FloatToStrF(cx_mm, ffFixed, 12, 4) + ' mm');
  Lines.Add('  polarO_Y = ' + FloatToStrF(cy_mm, ffFixed, 12, 4) + ' mm');
  Lines.Add('');

  { ---- Step 4: reference channel geometry ---- }
  Cls := D_FindClassByName(Board, ChanNames[0]);
  if Cls = Nil then
  begin
    Lines.Add('ERROR: Cannot find reference class object for ' + ChanNames[0]);
    Lines.SaveToFile(DIAG_OUT_PATH);
    Lines.Free; ChanNames.Free; PreBBoxes.Free;
    ChanSuffixes.Free; CompDesigs.Free;
    CompData.Free; TrackData.Free;
    ShowMessage('ERROR: reference class not found. Partial file at:' + #13#10 + DIAG_OUT_PATH);
    Exit;
  end;

  D_ComputeChannelBBox(Board, Cls, minX, minY, maxX, maxY, compCount);
  if compCount = 0 then
  begin
    Lines.Add('ERROR: Reference channel has no components.');
    Lines.SaveToFile(DIAG_OUT_PATH);
    Lines.Free; ChanNames.Free; PreBBoxes.Free;
    ChanSuffixes.Free; CompDesigs.Free;
    CompData.Free; TrackData.Free;
    ShowMessage('ERROR: reference channel empty. Partial file at:' + #13#10 + DIAG_OUT_PATH);
    Exit;
  end;

  refCX := (minX + maxX) div 2;
  refCY := (minY + maxY) div 2;
  refR_mm := Sqrt(Sqr(CoordToMMs(refCX - polarX)) +
                  Sqr(CoordToMMs(refCY - polarY)));
  angStep := 360.0 / N;

  Lines.Add('[REF_CHANNEL_GEOMETRY]');
  Lines.Add('  refClass  = ' + ChanNames[0]);
  Lines.Add('  refCX     = ' + D_Fmt(refCX) + ' mm');
  Lines.Add('  refCY     = ' + D_Fmt(refCY) + ' mm');
  Lines.Add('  refR_mm   = ' + FloatToStrF(refR_mm, ffFixed, 12, 4) + ' mm');
  Lines.Add('  angStep   = ' + D_FmtDeg(angStep) + ' deg  (360/' + IntToStr(N) + ')');
  Lines.Add('');

  if refR_mm < 0.01 then
  begin
    Lines.Add('WARNING: Reference bbox centre is at/near the polar origin.');
    Lines.Add('  (The real script would abort here -- no radial offset to propagate.)');
    Lines.Add('  Continuing diagnostic with this geometry for data purposes.');
    Lines.Add('');
  end;

  { ---- Step 5: pre-script per-channel snapshot ---- }
  D_SnapshotChannelBBoxes(Board, ChanNames, PreBBoxes);

  { ---- Step 6: derive class suffixes (v15 approach) ---- }
  ChanSuffixes.Clear;
  for i := 0 to ChanNames.Count - 1 do
  begin
    Cls := D_FindClassByName(Board, ChanNames[i]);
    if Cls <> Nil then
      ChanSuffixes.Add(D_DeriveClassSuffix(Board, Cls))
    else
      ChanSuffixes.Add('');
  end;

  { ---- Section: per-channel blocks ---- }
  for i := 0 to N - 1 do
  begin
    Cls := D_FindClassByName(Board, ChanNames[i]);
    suffix := ChanSuffixes[i];

    D_GetBBoxFromSnapshot(PreBBoxes, i,
                          preMinX, preMinY, preMaxX, preMaxY,
                          preCX, preCY, preCount);
    margin := D_ComputeMargin(preMinX, preMinY, preMaxX, preMaxY);

    Lines.Add('[CHANNEL ' + IntToStr(i) + ']');
    Lines.Add('  className    = ' + ChanNames[i]);
    Lines.Add('  suffix       = "' + suffix + '"');
    Lines.Add('  compCount    = ' + IntToStr(preCount));

    Lines.Add('  preBBox_minX = ' + D_Fmt(preMinX) + ' mm');
    Lines.Add('  preBBox_minY = ' + D_Fmt(preMinY) + ' mm');
    Lines.Add('  preBBox_maxX = ' + D_Fmt(preMaxX) + ' mm');
    Lines.Add('  preBBox_maxY = ' + D_Fmt(preMaxY) + ' mm');
    Lines.Add('  preBBox_ctrX = ' + D_Fmt(preCX) + ' mm');
    Lines.Add('  preBBox_ctrY = ' + D_Fmt(preCY) + ' mm');
    Lines.Add('  margin_mm    = ' + D_Fmt(margin) + ' mm');

    Lines.Add('  -- First ' + IntToStr(MAX_SAMPLE_COMPS) + ' components (pre-script state):');
    if Cls <> Nil then
      D_EmitChannelComponents(Board, Lines, Cls, MAX_SAMPLE_COMPS, '    ')
    else
      Lines.Add('    (class not found on board)');

    Lines.Add('  -- First ' + IntToStr(MAX_SAMPLE_PRIMS) + ' free primitives in bbox+margin:');
    if preCount > 0 then
      D_EmitFreePrimitives(Board, Lines,
                           preMinX, preMinY, preMaxX, preMaxY,
                           margin, MAX_SAMPLE_PRIMS, '    ')
    else
      Lines.Add('    (bbox empty -- no primitives queried)');

    Lines.Add('');
  end;

  { ---- Section: polar transform plan ---- }
  Lines.Add('[PLAN]');
  Lines.Add('  polarO         = (' + FloatToStrF(cx_mm, ffFixed, 12, 4) + ', ' +
                                     FloatToStrF(cy_mm, ffFixed, 12, 4) + ') mm');
  Lines.Add('  refCX/refCY    = (' + D_Fmt(refCX) + ', ' + D_Fmt(refCY) + ') mm');
  Lines.Add('  refR_mm        = ' + FloatToStrF(refR_mm, ffFixed, 12, 4) + ' mm');
  Lines.Add('  angStep        = ' + D_FmtDeg(angStep) + ' deg');
  Lines.Add('');
  Lines.Add('  NOTE on v15 track formula vs. alt formula:');
  Lines.Add('    v15 formula  : endpoint -> rotate(ep, pivot=preCXY, theta) + (newCXY - preCXY)');
  Lines.Add('    alt formula  : endpoint -> polarO + rotate(ep - polarO, theta)');
  Lines.Add('    (i.e. rotate each endpoint around polarO directly)');
  Lines.Add('  If tracks still look wrong after the real run, compare the two');
  Lines.Add('  predicted endpoint sets against where the tracks actually landed.');
  Lines.Add('');

  for i := 1 to N - 1 do
  begin
    rotateDeg := i * angStep;

    D_GetBBoxFromSnapshot(PreBBoxes, i,
                          preMinX, preMinY, preMaxX, preMaxY,
                          preCX, preCY, preCount);
    margin := D_ComputeMargin(preMinX, preMinY, preMaxX, preMaxY);

    { newCX/newCY: where this channel's components will end up.
      v15 formula: rotate refCXY around polarO by rotateDeg. }
    D_RotatePointXY(refCX, refCY, polarX, polarY, rotateDeg, newCX, newCY);

    Lines.Add('  [PLAN channel ' + IntToStr(i) + '  class=' + ChanNames[i] + ']');
    Lines.Add('    rotateDeg  = ' + D_FmtDeg(rotateDeg) + ' deg');
    Lines.Add('    newCX      = ' + D_Fmt(newCX) + ' mm  (component destination)');
    Lines.Add('    newCY      = ' + D_Fmt(newCY) + ' mm');
    Lines.Add('    preCX      = ' + D_Fmt(preCX) + ' mm  (pre-script channel centre)');
    Lines.Add('    preCY      = ' + D_Fmt(preCY) + ' mm');
    Lines.Add('');

    { Collect first 3 components in this channel via TStringList CSV }
    D_CollectFirstComps(Board, D_FindClassByName(Board, ChanNames[i]),
                        MAX_SAMPLE_COMPS, CompData);

    Lines.Add('    -- Predicted component positions (v15 formula):');
    Lines.Add('       Logic: after reset each comp sits at its refChan counterpart position.');
    Lines.Add('       Then TransformChannelComponents: rotate(comp, pivot=refCXY, theta) + (newCXY-refCXY).');
    Lines.Add('       Since post-reset comp = ref-comp, result = rotate(refComp, refCXY, theta) + delta.');
    Lines.Add('       Approximation here: rotate(current_comp_pos, refCXY, theta) + delta');
    Lines.Add('       (exact only if current state matches post-reset state).');

    for k := 0 to CompData.Count - 1 do
    begin
      if D_ParseCompCSV(CompData[k], cDesig, cX_, cY_, cRot_) then
      begin
        D_RotatePointXY(cX_, cY_, refCX, refCY, rotateDeg, pX, pY);
        pX := pX + (newCX - refCX);
        pY := pY + (newCY - refCY);
        predRot := cRot_ + rotateDeg;
        while predRot >= 360.0 do predRot := predRot - 360.0;
        while predRot < 0.0    do predRot := predRot + 360.0;
        Lines.Add('       comp[' + IntToStr(k) + '] desig=' + cDesig +
                  '  predX=' + D_Fmt(pX) + 'mm' +
                  '  predY=' + D_Fmt(pY) + 'mm' +
                  '  predRot=' + D_FmtDeg(predRot) + 'deg');
      end
      else
        Lines.Add('       comp[' + IntToStr(k) + '] parse error: ' + CompData[k]);
    end;
    if CompData.Count = 0 then
      Lines.Add('       (no components found for prediction)');
    Lines.Add('');

    { Collect first 3 free tracks in this channel's pre-script bbox via TStringList CSV }
    D_CollectFirstTracks(Board,
                         preMinX, preMinY, preMaxX, preMaxY, margin,
                         MAX_SAMPLE_TRACKS, TrackData);

    Lines.Add('    -- Predicted track endpoint positions:');
    Lines.Add('       v15 formula: pivot=preCXY, dest=newCXY');
    Lines.Add('         ep_out = rotate(ep, preCXY, theta) + (newCXY - preCXY)');
    Lines.Add('       alt formula: rotate ep around polarO directly');
    Lines.Add('         ep_out = polarO + rotate(ep - polarO, theta)');

    for k := 0 to TrackData.Count - 1 do
    begin
      if D_ParseTrackCSV(TrackData[k], tX1_, tY1_, tX2_, tY2_) then
      begin
        { v15 formula for X1/Y1 }
        D_RotatePointXY(tX1_, tY1_, preCX, preCY, rotateDeg, pX, pY);
        pX := pX + (newCX - preCX);
        pY := pY + (newCY - preCY);

        { v15 formula for X2/Y2 }
        D_RotatePointXY(tX2_, tY2_, preCX, preCY, rotateDeg, pX2, pY2);
        pX2 := pX2 + (newCX - preCX);
        pY2 := pY2 + (newCY - preCY);

        Lines.Add('       track[' + IntToStr(k) + ']  original:' +
                  '  X1=' + D_Fmt(tX1_) + 'mm' +
                  '  Y1=' + D_Fmt(tY1_) + 'mm' +
                  '  X2=' + D_Fmt(tX2_) + 'mm' +
                  '  Y2=' + D_Fmt(tY2_) + 'mm');
        Lines.Add('              v15-pred :' +
                  '  X1=' + D_Fmt(pX)   + 'mm' +
                  '  Y1=' + D_Fmt(pY)   + 'mm' +
                  '  X2=' + D_Fmt(pX2)  + 'mm' +
                  '  Y2=' + D_Fmt(pY2)  + 'mm');

        { alt formula: rotate each endpoint around polarO directly }
        D_RotatePointXY(tX1_, tY1_, polarX, polarY, rotateDeg, altX,  altY);
        D_RotatePointXY(tX2_, tY2_, polarX, polarY, rotateDeg, altX2, altY2);

        Lines.Add('              alt-pred :' +
                  '  X1=' + D_Fmt(altX)  + 'mm' +
                  '  Y1=' + D_Fmt(altY)  + 'mm' +
                  '  X2=' + D_Fmt(altX2) + 'mm' +
                  '  Y2=' + D_Fmt(altY2) + 'mm');
      end
      else
        Lines.Add('       track[' + IntToStr(k) + '] parse error: ' + TrackData[k]);
    end;

    if TrackData.Count = 0 then
      Lines.Add('       (no free tracks found in pre-script bbox+margin)');

    Lines.Add('');
  end;

  { ---- Footer ---- }
  Lines.Add('[DONE]');
  Lines.Add('  Diagnostic written to: ' + DIAG_OUT_PATH);
  Lines.Add('  No primitives were moved during this run.');

  Lines.SaveToFile(DIAG_OUT_PATH);
  Lines.Free;
  ChanNames.Free;
  PreBBoxes.Free;
  ChanSuffixes.Free;
  CompDesigs.Free;
  CompData.Free;
  TrackData.Free;

  ShowMessage('Diagnostic complete.' + #13#10 +
              'File written to:' + #13#10 +
              DIAG_OUT_PATH + #13#10 + #13#10 +
              'Open the file in any text editor to review per-channel data' + #13#10 +
              'and the dual track-endpoint predictions.');
end;
