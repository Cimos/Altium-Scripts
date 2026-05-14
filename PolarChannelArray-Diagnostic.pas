{*******************************************************************************
  PolarChannelArray-Diagnostic.pas
  Instrumented diagnostic variant of PolarChannelArray.pas v13 (commit cf3865b).

  PURPOSE
  -------
  Diagnoses why ResetChannelsToMatchReference returned 0 snapped components.
  Does NOT perform the polar transform (that step is commented out).
  DOES run ResetChannelsToMatchReference so that all matching attempts are
  exercised and logged.

  OUTPUT
  ------
  Writes <ProjectDir>\polar-array-diagnostic.log (persistent, grep-able).
  The Done dialog shows the same summary as v13 plus a "log written to <path>"
  footer.

  HOW TO INVOKE
  -------------
  (A) Preferred -- Altium Scripts panel (X2 CLI is broken on AD26):
      Tools > Run Script... > PolarChannelArray-Diagnostic.pas >
      ArrangeChannelsInPolarArray_Diag

  (B) X2 CLI (broken on AD26 -- kept for documentation, see
      production-agents/memory/project_altium_x2_not_headless.md):
      & "C:\Program Files\Altium\AD26\X2.exe" `
        -RunScript:"E:\git\Projects\Altium-Scripts\PolarChannelArray-Diagnostic.pas:ArrangeChannelsInPolarArray_Diag"

  WHAT IS LOGGED
  --------------
  For each of the N channels:
    * Class name as returned by FindClassByName
    * CountClassMembers result
    * Up to 5 component designators (Comp.Name.Text) verbatim
    * For each of those 5: StripChannelSuffix result + FindMatchingComponent hit/miss
    * For each component: union-group membership (Comp.GroupId if available,
      else UNION_UNKNOWN with explanation)
    * Bounding-rect centre (mm)

  Bottom of log: three explicit probes:
    A. OBSERVED_SUFFIX_PATTERN across reference-channel sample
    B. Iterator total vs class-member sum (mismatch -> union/filter issue)
    C. Union probe: count + first 10 designators of unionised components

  WHAT IS CHANGED FROM v13
  ------------------------
  ONLY additions:
  * New helper OpenDiagLog / WriteDiagLine / CloseDiagLog (file I/O)
  * New helper SampleChannelComponents (wraps FindMatchingComponent + suffix log)
  * New helper ProbeUnionMembership (wraps Comp.GroupId access)
  * New helper CountBoardComponents (full iterator total for probe B)
  * Modified ArrangeChannelsInPolarArray_Diag (entry point renamed _Diag):
      - opens log before confirmation dialog
      - logs channel inventory after Step 4
      - logs ResetChannelsToMatchReference per-component attempts inline
        (the function is inlined here to intercept each iteration)
      - probes A/B/C written at bottom of log
      - polar transform block is commented out

  APIs used in NEW code only:
    * TStringList.Add / .SaveToFile  [verified: pattern used throughout
      PolarChannelArray.pas; safe in DelphiScript on AD25/AD26]
      ORIGINAL attempt used AssignFile/Rewrite/WriteLn/CloseFile with a
      TextFile variable -- caused "Error in declaration block" at compile
      time on AD26. DelphiScript does not expose TextFile. Refactored
      2026-05-14.
    * Comp.GroupId  [deduced: documented at techdocs.altium.com/display/ADOH/
      IPCB_Component; "GroupId" is the union membership integer, 0 = not in a
      union -- see UNION NOTE in ProbeUnionMembership for fallback]

  Verified APIs (inherited verbatim from v13, unchanged):
    * All helpers listed in altium-pcb-api-reference.md Section 1-10
      [verified, PolarChannelArray.pas:1-1342]

  PATTERNS REUSED FROM v13 (cited at each helper site below):
    PolarChannelArray.pas:116-121  -- consts block
    PolarChannelArray.pas:224-248  -- FindClassByName
    PolarChannelArray.pas:254-272  -- CountClassMembers
    PolarChannelArray.pas:585-599  -- StripChannelSuffix
    PolarChannelArray.pas:607-637  -- FindMatchingComponent
    PolarChannelArray.pas:659-714  -- ResetChannelsToMatchReference
                                      (inlined here for per-component logging)
*******************************************************************************}

const
  DEG_TO_RAD             = 0.017453292519943;
  MAX_CHANNELS_SAFETY    = 256;
  COMP_CLASS_MEMBER_KIND = 1;
  MARGIN_FRACTION        = 0.25;
  MARGIN_MIN_MM          = 5.0;
  MARGIN_MAX_MM          = 50.0;
  MAX_SAMPLE_COMPS       = 5;   { max designators to log per channel }

{ ===========================================================================
  DIAGNOSTIC LOG STATE
  DelphiScript does not expose TextFile/AssignFile/Rewrite, so we accumulate
  lines into a TStringList and SaveToFile at close. [verified: TStringList
  pattern used throughout PolarChannelArray.pas; TextFile attempted in this
  file caused "Error in declaration block" 2026-05-14]
=========================================================================== }
var
  gLogLines  : TStringList;
  gLogPath   : String;
  gLogOpen   : Boolean;

{ --------------------------------------------------------------------------- }
procedure OpenDiagLog(path : String);
begin
  gLogPath := path;
  gLogOpen := False;
  try
    gLogLines := TStringList.Create;
    gLogLines.Add('=== PolarChannelArray-Diagnostic run ===');
    gLogLines.Add('Date/time: ' + DateTimeToStr(Now));
    gLogLines.Add('');
    gLogOpen := True;
  except
    ShowMessage('WARNING: Could not allocate diagnostic log.' + #13#10 +
                'Logging will be skipped; dialogs still show.');
    gLogOpen := False;
  end;
end;

{ --------------------------------------------------------------------------- }
procedure WriteDiagLine(s : String);
begin
  if gLogOpen then
  begin
    try
      gLogLines.Add(s);
    except
      { swallow add errors -- keep script running }
    end;
  end;
end;

{ --------------------------------------------------------------------------- }
procedure CloseDiagLog;
begin
  if gLogOpen then
  begin
    try
      gLogLines.SaveToFile(gLogPath);
    except
      ShowMessage('WARNING: failed to save diagnostic log to ' + gLogPath);
    end;
    try
      gLogLines.Free;
    except
    end;
    gLogOpen := False;
  end;
end;

{ ===========================================================================
  COPIED HELPERS FROM v13 (unchanged)
  Each function carries a cite to the line range in PolarChannelArray.pas.
=========================================================================== }

{ pattern from PolarChannelArray.pas:125-139 }
procedure RotatePointXY(ix, iy        : TCoord;
                        cx, cy        : TCoord;
                        angleDeg      : Double;
                        var ox, oy    : TCoord);
var
  rad, cosA, sinA, dx, dy : Double;
begin
  rad  := angleDeg * DEG_TO_RAD;
  cosA := Cos(rad);
  sinA := Sin(rad);
  dx   := CoordToMMs(ix - cx);
  dy   := CoordToMMs(iy - cy);
  ox   := cx + MMsToCoord(dx * cosA - dy * sinA);
  oy   := cy + MMsToCoord(dx * sinA + dy * cosA);
end;

{ pattern from PolarChannelArray.pas:142-147 }
function NormaliseAngle(a : Double) : Double;
begin
  Result := a;
  while Result < 0      do Result := Result + 360.0;
  while Result >= 360.0 do Result := Result - 360.0;
end;

{ pattern from PolarChannelArray.pas:150-153 }
function PointInRect(x, y, x1, y1, x2, y2 : TCoord) : Boolean;
begin
  Result := (x >= x1) and (x <= x2) and (y >= y1) and (y <= y2);
end;

{ pattern from PolarChannelArray.pas:156-181 }
function PrimitiveKey(Prim : IPCB_Primitive) : String;
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

{ pattern from PolarChannelArray.pas:198-221 }
function IsBuiltInComponentClass(Cls : IPCB_ObjectClass) : Boolean;
var
  nm : String;
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

{ pattern from PolarChannelArray.pas:224-248 }
function FindClassByName(Board : IPCB_Board; name : String) : IPCB_ObjectClass;
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
    if (Cls.MemberKind = COMP_CLASS_MEMBER_KIND) and (Cls.Name = name) then
    begin
      Result := Cls;
      Break;
    end;
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ pattern from PolarChannelArray.pas:254-272 }
function CountClassMembers(Board : IPCB_Board; Cls : IPCB_ObjectClass) : Integer;
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

{ pattern from PolarChannelArray.pas:275-321 }
procedure ComputeChannelBBox(Board : IPCB_Board;
                             Cls   : IPCB_ObjectClass;
                             var minX, minY, maxX, maxY : TCoord;
                             var count : Integer);
var
  Iter : IPCB_BoardIterator;
  Comp : IPCB_Component;
  L, B, R, T : TCoord;
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
      L := Comp.BoundingRectangle.Left;
      B := Comp.BoundingRectangle.Bottom;
      R := Comp.BoundingRectangle.Right;
      T := Comp.BoundingRectangle.Top;
      if count = 0 then
      begin
        minX := L; minY := B; maxX := R; maxY := T;
      end
      else
      begin
        if L < minX then minX := L;
        if B < minY then minY := B;
        if R > maxX then maxX := R;
        if T > maxY then maxY := T;
      end;
      count := count + 1;
    end;
    Comp := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ pattern from PolarChannelArray.pas:544-574 }
procedure CollectMatchingClasses(Board     : IPCB_Board;
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
    if (Cls.MemberKind = COMP_CLASS_MEMBER_KIND) and
       (not IsBuiltInComponentClass(Cls)) and
       (AnsiUpperCase(Copy(Cls.Name, 1, Length(prefix))) =
        AnsiUpperCase(prefix)) and
       (CountClassMembers(Board, Cls) > 0) then
    begin
      if ChanNames.Count < MAX_CHANNELS_SAFETY then
        ChanNames.Add(Cls.Name);
    end;
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ pattern from PolarChannelArray.pas:585-599 }
function StripChannelSuffix(designator, className : String) : String;
var
  suffix : String;
  desigLen, suffLen : Integer;
begin
  suffix := '_' + className;
  desigLen := Length(designator);
  suffLen := Length(suffix);
  if (desigLen >= suffLen) and
     (AnsiUpperCase(Copy(designator, desigLen - suffLen + 1, suffLen)) =
      AnsiUpperCase(suffix)) then
    Result := Copy(designator, 1, desigLen - suffLen)
  else
    Result := designator;
end;

{ pattern from PolarChannelArray.pas:607-637 }
function FindMatchingComponent(Board : IPCB_Board;
                               Cls : IPCB_ObjectClass;
                               className : String;
                               targetRoot : String) : IPCB_Component;
var
  Iter : IPCB_BoardIterator;
  Comp : IPCB_Component;
  root : String;
begin
  Result := Nil;
  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Comp := Iter.FirstPCBObject;
  while Comp <> Nil do
  begin
    if Cls.IsMember(Comp) then
    begin
      root := StripChannelSuffix(Comp.Name.Text, className);
      if AnsiUpperCase(root) = AnsiUpperCase(targetRoot) then
      begin
        Result := Comp;
        Break;
      end;
    end;
    Comp := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ pattern from PolarChannelArray.pas:731-767 }
function FindSelectedComponent(Board : IPCB_Board) : IPCB_Component;
var
  i, n : Integer;
  Prim : IPCB_Primitive;
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

{ pattern from PolarChannelArray.pas:775-816 }
function FindComponentAtLocation(Board : IPCB_Board;
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

{ pattern from PolarChannelArray.pas:826-856 }
function FindChannelClassForComponent(Board : IPCB_Board;
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
    if (Cls.MemberKind = COMP_CLASS_MEMBER_KIND) and
       (not IsBuiltInComponentClass(Cls)) and
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

{ pattern from PolarChannelArray.pas:866-919 }
function DerivePrefixFromReference(Board   : IPCB_Board;
                                   refName : String)    : String;
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
    if (Cls.MemberKind = COMP_CLASS_MEMBER_KIND) and
       (not IsBuiltInComponentClass(Cls)) and
       (AnsiUpperCase(Cls.Name) <> AnsiUpperCase(refName)) and
       (CountClassMembers(Board, Cls) > 0) then
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

{ ===========================================================================
  NEW DIAGNOSTIC HELPERS
=========================================================================== }

{ ---------------------------------------------------------------------------
  ProbeUnionMembership
  Attempts to read the union/group ID from a component.

  UNION NOTE (deduced from Altium PCB object model):
  Altium exposes union membership via IPCB_Component.GroupId (an integer).
  GroupId = 0 means not in a union. GroupId > 0 means the component is
  a member of the union with that group number. This property is documented
  at techdocs.altium.com/display/ADOH/IPCB_Component but has NOT been
  empirically verified against AD25/AD26 in this repo's prior art.

  The call is wrapped in try/except. If the property does not exist on this
  Altium build, the output line will say UNION_UNKNOWN instead of a number.
  That itself is diagnostic data.

  Returns a string like "0 (not in union)", "3 (IN UNION)", or
  "UNION_UNKNOWN (GroupId property absent on this Altium build)".
--------------------------------------------------------------------------- }
function ProbeUnionMembership(Comp : IPCB_Component) : String;
begin
  // GroupId / UnionId / Union accessors are NOT in the verified Altium PCB
  // API surface for IPCB_Component on AD25/AD26. The agent originally tried
  // Comp.GroupId -- DelphiScript rejected with "Undeclared identifier" at
  // compile time. The prior-art corpus in Altium-Scripts repo contains no
  // verified union-membership accessor either.
  //
  // To check whether a union is affecting the reset, break the union
  // manually in Altium (Tools > Component Actions > Disband Component
  // Union, or right-click the unionised component > Component Actions)
  // and rerun this diagnostic. If "Reset snapped 0 -> non-zero", the
  // union mattered.
  Result := 'UNION_UNKNOWN (no verified API; see comment in ProbeUnionMembership)';
end;

{ ---------------------------------------------------------------------------
  CountBoardComponents
  Returns total components seen by a full-board eComponentObject iterator.
  Used for probe B: iterator total vs sum-of-class-members.
  [verified: pattern from PolarChannelArray.pas:259-270 -- CountClassMembers]
--------------------------------------------------------------------------- }
function CountBoardComponents(Board : IPCB_Board) : Integer;
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
    Result := Result + 1;
    Comp := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);
end;

{ ---------------------------------------------------------------------------
  LogChannelInventory
  For a single channel: logs class name, member count, up to 5 designators
  with suffix-strip and FindMatchingComponent results, union membership,
  and bbox centre.

  RefCls / RefClsName are the reference channel's class and name, used to
  test FindMatchingComponent on each sampled component.

  Returns the designator of the first sampled component (for probe A suffix
  analysis; caller accumulates).
--------------------------------------------------------------------------- }
function LogChannelInventory(Board       : IPCB_Board;
                             chanIdx     : Integer;
                             clsName     : String;
                             Cls         : IPCB_ObjectClass;
                             RefCls      : IPCB_ObjectClass;
                             RefClsName  : String;
                             isRef       : Boolean) : String;
var
  Iter        : IPCB_BoardIterator;
  Comp        : IPCB_Component;
  sampleCount : Integer;
  memberCount : Integer;
  root        : String;
  matchComp   : IPCB_Component;
  matchStr    : String;
  unionStr    : String;
  cx_mm, cy_mm : Double;
  minX, minY, maxX, maxY : TCoord;
  bboxCount   : Integer;
  firstDesig  : String;
begin
  firstDesig := '';

  if Cls = Nil then
  begin
    WriteDiagLine('  CLASS NOT FOUND via FindClassByName -- cannot log inventory');
    Result := '';
    Exit;
  end;

  { Member count }
  memberCount := CountClassMembers(Board, Cls);
  WriteDiagLine('  CountClassMembers: ' + IntToStr(memberCount));

  { Bbox centre }
  ComputeChannelBBox(Board, Cls, minX, minY, maxX, maxY, bboxCount);
  if bboxCount > 0 then
  begin
    cx_mm := CoordToMMs((minX + maxX) div 2);
    cy_mm := CoordToMMs((minY + maxY) div 2);
    WriteDiagLine('  BBox centre (mm): (' +
                  FloatToStrF(cx_mm, ffFixed, 10, 3) + ', ' +
                  FloatToStrF(cy_mm, ffFixed, 10, 3) + ')');
  end
  else
    WriteDiagLine('  BBox centre: N/A (0 components in bbox)');

  { Sample up to 5 components }
  WriteDiagLine('  Component sample (up to ' + IntToStr(MAX_SAMPLE_COMPS) + '):');
  sampleCount := 0;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(eComponentObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Comp := Iter.FirstPCBObject;
  while (Comp <> Nil) and (sampleCount < MAX_SAMPLE_COMPS) do
  begin
    if Cls.IsMember(Comp) then
    begin
      if sampleCount = 0 then firstDesig := Comp.Name.Text;

      { Strip suffix }
      root := StripChannelSuffix(Comp.Name.Text, clsName);

      { Try FindMatchingComponent on the REFERENCE class }
      if isRef then
        matchStr := '(this IS the reference class -- no cross-match needed)'
      else
      begin
        matchComp := FindMatchingComponent(Board, RefCls, RefClsName, root);
        if matchComp <> Nil then
          matchStr := 'FOUND in ref as "' + matchComp.Name.Text + '"'
        else
          matchStr := 'NOT FOUND in ref class';
      end;

      { Union probe }
      unionStr := ProbeUnionMembership(Comp);

      WriteDiagLine('    [' + IntToStr(sampleCount) + '] Designator: "' +
                    Comp.Name.Text + '"');
      WriteDiagLine('         StripSuffix("' + Comp.Name.Text + '","' +
                    clsName + '") -> "' + root + '"');
      WriteDiagLine('         FindMatchingComponent: ' + matchStr);
      WriteDiagLine('         GroupId: ' + unionStr);

      sampleCount := sampleCount + 1;
    end;
    Comp := Iter.NextPCBObject;
  end;

  Board.BoardIterator_Destroy(Iter);

  if sampleCount = 0 then
    WriteDiagLine('    (no components iterated for this class)');

  Result := firstDesig;
end;

{ ---------------------------------------------------------------------------
  ResetChannelsToMatchReference_Diag
  Instrumented version of ResetChannelsToMatchReference from v13 lines 659-714.
  Logs each attempted match and the outcome. Returns count matched.

  Pattern from PolarChannelArray.pas:659-714
--------------------------------------------------------------------------- }
function ResetChannelsToMatchReference_Diag(Board      : IPCB_Board;
                                            RefCls     : IPCB_ObjectClass;
                                            RefClsName : String;
                                            ChanNames  : TStringList) : Integer;
var
  CompIter : IPCB_BoardIterator;
  Comp, refComp : IPCB_Component;
  i : Integer;
  otherClsName : String;
  otherCls : IPCB_ObjectClass;
  root : String;
  matched : Integer;
  chanMatched : Integer;
  chanTotal : Integer;
begin
  matched := 0;

  WriteDiagLine('');
  WriteDiagLine('=== ResetChannelsToMatchReference_Diag ===');
  WriteDiagLine('Reference class: "' + RefClsName + '"');
  WriteDiagLine('Non-reference channels to process: ' +
                IntToStr(ChanNames.Count - 1));

  for i := 1 to ChanNames.Count - 1 do
  begin
    otherClsName := ChanNames[i];
    WriteDiagLine('');
    WriteDiagLine('--- Channel [' + IntToStr(i) + ']: "' + otherClsName + '" ---');

    otherCls := FindClassByName(Board, otherClsName);
    if otherCls = Nil then
    begin
      WriteDiagLine('  RESULT: FindClassByName returned NIL -- skipping');
      Continue;
    end;
    WriteDiagLine('  FindClassByName: OK');

    chanMatched := 0;
    chanTotal   := 0;

    CompIter := Board.BoardIterator_Create;
    CompIter.AddFilter_ObjectSet(MkSet(eComponentObject));
    CompIter.AddFilter_LayerSet(AllLayers);
    CompIter.AddFilter_Method(eProcessAll);

    Comp := CompIter.FirstPCBObject;
    while Comp <> Nil do
    begin
      if otherCls.IsMember(Comp) then
      begin
        chanTotal := chanTotal + 1;
        root := StripChannelSuffix(Comp.Name.Text, otherClsName);
        refComp := FindMatchingComponent(Board, RefCls, RefClsName, root);
        if refComp <> Nil then
        begin
          { DO move the component -- the reset step must actually run so the
            iterator covers the real execution path. }
          Comp.X        := refComp.X;
          Comp.Y        := refComp.Y;
          Comp.Rotation := refComp.Rotation;
          Comp.Layer    := refComp.Layer;
          Comp.GraphicallyInvalidate;
          chanMatched := chanMatched + 1;
          matched     := matched + 1;
          WriteDiagLine('  MATCH: "' + Comp.Name.Text + '" root="' + root +
                        '" -> ref "' + refComp.Name.Text + '" MOVED');
        end
        else
        begin
          WriteDiagLine('  NO MATCH: "' + Comp.Name.Text + '" root="' + root +
                        '" -> not found in ref class "' + RefClsName + '"');
        end;
      end;
      Comp := CompIter.NextPCBObject;
    end;

    Board.BoardIterator_Destroy(CompIter);

    WriteDiagLine('  Channel summary: iterated=' + IntToStr(chanTotal) +
                  '  matched=' + IntToStr(chanMatched));
  end;

  WriteDiagLine('');
  WriteDiagLine('ResetChannelsToMatchReference_Diag TOTAL matched: ' +
                IntToStr(matched));

  Result := matched;
end;

{ ===========================================================================
  ENTRY POINT
=========================================================================== }
procedure ArrangeChannelsInPolarArray_Diag;
var
  Board     : IPCB_Board;
  Cls       : IPCB_ObjectClass;

  ChanNames      : TStringList;
  PreBBoxes      : TStringList;

  i, N, compCount, refIdx : Integer;
  prefix, inputStr, refClassName : String;
  cx_mm, cy_mm : Double;
  CX, CY    : TCoord;
  refX, refY : TCoord;
  refComp   : IPCB_Component;
  rotateDeg : Double;
  newCX, newCY : TCoord;
  minX, minY, maxX, maxY, margin : TCoord;
  refCX, refCY : TCoord;
  refR_mm : Double;
  summary : String;
  resetMatched : Integer;
  preMinX, preMinY, preMaxX, preMaxY : TCoord;
  preCX, preCY : TCoord;
  preCount : Integer;

  { Diagnostic-specific locals }
  logPath       : String;
  projDir       : String;
  iterTotal     : Integer;
  classMemberSum : Integer;
  firstDesig    : String;
  suffixProbe   : String;
  unionCount    : Integer;
  unionList     : String;
  unionGid      : Integer;
  CompIter2     : IPCB_BoardIterator;
  Comp2         : IPCB_Component;
  unionListCount : Integer;
begin
  gLogOpen := False;

  Board := PCBServer.GetCurrentPCBBoard;
  if Board = Nil then
  begin
    ShowMessage('ERROR: No PCB document is currently active.');
    Exit;
  end;

  { ---- Open diagnostic log ---- }
  { ProjectDir from the board's file path. Strip the filename to get the dir. }
  projDir := Board.FileName;
  { Strip filename: walk back to last backslash }
  i := Length(projDir);
  while (i > 0) and (projDir[i] <> '\') do i := i - 1;
  projDir := Copy(projDir, 1, i);
  if projDir = '' then projDir := 'C:\Temp\';

  logPath := projDir + 'polar-array-diagnostic.log';
  OpenDiagLog(logPath);
  WriteDiagLine('Board file: ' + Board.FileName);
  WriteDiagLine('');

  { ---- Step 1: Pick reference component ---- }
  { pattern from PolarChannelArray.pas:1070-1104 }
  WriteDiagLine('=== Step 1: Pick reference component ===');
  refComp := FindSelectedComponent(Board);

  if refComp = Nil then
  begin
    WriteDiagLine('No pre-selected component found -- prompting for click.');
    ShowMessage('DIAGNOSTIC RUN (no polar transform will occur).' + #13#10 +
                'Click any component in the REFERENCE channel.');

    if not Board.ChooseLocation(refX, refY, 'Click a component in the reference channel') then
    begin
      WriteDiagLine('User cancelled ChooseLocation. Exiting.');
      CloseDiagLog;
      Exit;
    end;

    refComp := FindComponentAtLocation(Board, refX, refY);
    if refComp = Nil then
    begin
      WriteDiagLine('FindComponentAtLocation returned nil. Exiting.');
      ShowMessage('ERROR: No component found near clicked location.');
      CloseDiagLog;
      Exit;
    end;
  end
  else
    WriteDiagLine('Pre-selected component found -- skip click.');

  WriteDiagLine('Reference component Name.Text: "' + refComp.Name.Text + '"');
  WriteDiagLine('Reference component X (mm): ' +
                FloatToStrF(CoordToMMs(refComp.X), ffFixed, 10, 3));
  WriteDiagLine('Reference component Y (mm): ' +
                FloatToStrF(CoordToMMs(refComp.Y), ffFixed, 10, 3));

  refClassName := FindChannelClassForComponent(Board, refComp);
  WriteDiagLine('FindChannelClassForComponent result: "' + refClassName + '"');

  if Trim(refClassName) = '' then
  begin
    WriteDiagLine('FATAL: refClassName is empty -- component has no user-defined class.');
    ShowMessage('ERROR: Clicked component has no user-defined component class.' +
                #13#10 + 'Has the multi-channel project been compiled?');
    CloseDiagLog;
    Exit;
  end;

  prefix := DerivePrefixFromReference(Board, refClassName);
  WriteDiagLine('DerivePrefixFromReference result: "' + prefix + '"');

  if prefix = '' then
  begin
    WriteDiagLine('FATAL: prefix is empty -- no sibling classes share a prefix.');
    ShowMessage('ERROR: Could not derive channel prefix from "' + refClassName + '".');
    CloseDiagLog;
    Exit;
  end;

  { ---- Step 2: Collect matching classes ---- }
  WriteDiagLine('');
  WriteDiagLine('=== Step 2: Collect matching classes (prefix "' + prefix + '") ===');

  ChanNames := TStringList.Create;
  ChanNames.Sorted := True;
  ChanNames.Duplicates := dupIgnore;

  CollectMatchingClasses(Board, prefix, ChanNames);

  N := ChanNames.Count;
  WriteDiagLine('CollectMatchingClasses found ' + IntToStr(N) + ' channels:');
  for i := 0 to N - 1 do
    WriteDiagLine('  [' + IntToStr(i) + '] "' + ChanNames[i] + '"');

  if N < 2 then
  begin
    WriteDiagLine('FATAL: fewer than 2 channels. Cannot run.');
    ShowMessage('Only ' + IntToStr(N) + ' channel(s) found for prefix "' + prefix + '".');
    ChanNames.Free;
    CloseDiagLog;
    Exit;
  end;

  { Move reference to index 0 }
  refIdx := ChanNames.IndexOf(refClassName);
  WriteDiagLine('refClassName "' + refClassName + '" at ChanNames index: ' +
                IntToStr(refIdx));
  if refIdx < 0 then
  begin
    WriteDiagLine('FATAL: reference class not in matched set.');
    ShowMessage('ERROR: Reference class "' + refClassName + '" not in matched set.');
    ChanNames.Free;
    CloseDiagLog;
    Exit;
  end;
  if refIdx > 0 then
  begin
    ChanNames.Sorted := False;
    ChanNames.Move(refIdx, 0);
    WriteDiagLine('Moved reference to index 0. Final order:');
    for i := 0 to N - 1 do
      WriteDiagLine('  [' + IntToStr(i) + '] "' + ChanNames[i] + '"');
  end;

  { ---- Step 3: Origin -- needed for measurement, skip user click in diag ---- }
  WriteDiagLine('');
  WriteDiagLine('=== Step 3: Pick polar origin ===');
  WriteDiagLine('(Proceeding with origin selection as normal; transform will be commented out)');

  if MessageDlg(
       'DIAGNOSTIC RUN -- polar transform will NOT execute.' + #13#10 +
       'Step 2 of 2: Click the polar origin point on the PCB.' + #13#10 + #13#10 +
       'Yes = click to pick origin  /  No = type coordinates manually',
       mtConfirmation, mbYesNo, 0) = mrYes then
  begin
    if not Board.ChooseLocation(CX, CY, 'Click the polar origin point') then
    begin
      WriteDiagLine('User cancelled origin selection. Exiting.');
      ChanNames.Free;
      CloseDiagLog;
      Exit;
    end;
    cx_mm := CoordToMMs(CX);
    cy_mm := CoordToMMs(CY);
  end
  else
  begin
    inputStr := InputBox('Polar Channel Array - Origin', 'Polar origin X (mm):', '0');
    if Trim(inputStr) = '' then begin ChanNames.Free; CloseDiagLog; Exit; end;
    cx_mm := StrToFloatDef(inputStr, 0.0);

    inputStr := InputBox('Polar Channel Array - Origin', 'Polar origin Y (mm):', '0');
    if Trim(inputStr) = '' then begin ChanNames.Free; CloseDiagLog; Exit; end;
    cy_mm := StrToFloatDef(inputStr, 0.0);

    CX := MMsToCoord(cx_mm);
    CY := MMsToCoord(cy_mm);
  end;

  WriteDiagLine('Polar origin: (' + FloatToStrF(cx_mm, ffFixed, 10, 3) + ', ' +
                FloatToStrF(cy_mm, ffFixed, 10, 3) + ') mm');

  { ---- Step 4: Measure reference channel ---- }
  WriteDiagLine('');
  WriteDiagLine('=== Step 4: Measure reference channel ===');

  Cls := FindClassByName(Board, ChanNames[0]);
  if Cls = Nil then
  begin
    WriteDiagLine('FATAL: FindClassByName("' + ChanNames[0] + '") returned nil.');
    ShowMessage('ERROR: Could not find reference class ' + ChanNames[0]);
    ChanNames.Free;
    CloseDiagLog;
    Exit;
  end;

  ComputeChannelBBox(Board, Cls, minX, minY, maxX, maxY, compCount);
  WriteDiagLine('Reference channel bbox compCount: ' + IntToStr(compCount));

  if compCount = 0 then
  begin
    WriteDiagLine('FATAL: Reference channel has no components.');
    ShowMessage('ERROR: Reference channel has no components.');
    ChanNames.Free;
    CloseDiagLog;
    Exit;
  end;

  refCX := (minX + maxX) div 2;
  refCY := (minY + maxY) div 2;
  refR_mm := Sqrt(Sqr(CoordToMMs(refCX - CX)) + Sqr(CoordToMMs(refCY - CY)));

  WriteDiagLine('Reference bbox centre (mm): (' +
                FloatToStrF(CoordToMMs(refCX), ffFixed, 10, 3) + ', ' +
                FloatToStrF(CoordToMMs(refCY), ffFixed, 10, 3) + ')');
  WriteDiagLine('Derived radius (mm): ' +
                FloatToStrF(refR_mm, ffFixed, 10, 3));

  if refR_mm < 0.01 then
  begin
    WriteDiagLine('WARNING: radius < 0.01 mm -- reference bbox centre is at the origin.');
    { Don't exit -- still want to log the channel inventory. }
  end;

  { ---- Confirmation dialog matching v13 ---- }
  { pattern from PolarChannelArray.pas:1228-1260 }
  summary := 'DIAGNOSTIC RUN -- polar transform commented out' + #13#10 +
             'Reference: ' + refClassName + #13#10 +
             'Prefix: "' + prefix + '"' + #13#10 +
             'Channels (' + IntToStr(N) + '): ';
  for i := 0 to N - 1 do
  begin
    if i > 0 then summary := summary + ', ';
    summary := summary + ChanNames[i];
  end;
  summary := summary + #13#10 +
             'Radius: ' + FloatToStrF(refR_mm, ffFixed, 10, 3) + ' mm' + #13#10 +
             'Angular step: ' + FloatToStrF(360.0 / N, ffFixed, 10, 3) + ' deg' + #13#10 + #13#10 +
             'Proceed? (Reset WILL run; transform will NOT run.)';

  if MessageDlg(summary, mtConfirmation, mbYesNo, 0) <> mrYes then
  begin
    WriteDiagLine('User cancelled at confirmation dialog. Exiting.');
    ChanNames.Free;
    CloseDiagLog;
    Exit;
  end;

  { ---- Log channel inventory ---- }
  WriteDiagLine('');
  WriteDiagLine('=== Channel inventory (before reset) ===');

  suffixProbe := '';
  for i := 0 to N - 1 do
  begin
    WriteDiagLine('');
    if i = 0 then
      WriteDiagLine('Channel [' + IntToStr(i) + ']: "' + ChanNames[i] + '" (REFERENCE)')
    else
      WriteDiagLine('Channel [' + IntToStr(i) + ']: "' + ChanNames[i] + '"');

    Cls := FindClassByName(Board, ChanNames[i]);
    if Cls = Nil then
    begin
      WriteDiagLine('  FindClassByName: NIL');
      Continue;
    end
    else
      WriteDiagLine('  FindClassByName: OK (class object found)');

    firstDesig := LogChannelInventory(Board, i, ChanNames[i], Cls,
                                      FindClassByName(Board, ChanNames[0]),
                                      ChanNames[0],
                                      (i = 0));

    { Only accumulate suffix probe from reference channel samples }
    if (i = 0) and (firstDesig <> '') then
      suffixProbe := firstDesig;
  end;

  { ---- Step 7b: Run reset (instrumented) ---- }
  WriteDiagLine('');
  WriteDiagLine('=== Step 7b: Run ResetChannelsToMatchReference_Diag ===');

  PCBServer.PreProcess;
  resetMatched := ResetChannelsToMatchReference_Diag(
                    Board,
                    FindClassByName(Board, ChanNames[0]),
                    ChanNames[0],
                    ChanNames);
  PCBServer.PostProcess;
  Board.GraphicallyInvalidate;

  // ---- POLAR TRANSFORM COMMENTED OUT ----
  // The transform is intentionally NOT run in this diagnostic build.
  // When the root cause is confirmed and a fix applied, remove these
  // line-comments and delete this note.
  //
  //   PreBBoxes := TStringList.Create;
  //   SnapshotChannelBBoxes(Board, ChanNames, PreBBoxes);
  //   DoneSet := TStringList.Create; ...
  //   PCBServer.PreProcess;
  //   for i := 1 to N - 1 do begin ... end;
  //   PCBServer.PostProcess;
  // ----

  { ---- Probe A: OBSERVED_SUFFIX_PATTERN ---- }
  WriteDiagLine('');
  WriteDiagLine('=== PROBE A: Designator-format (suffix pattern) ===');
  if suffixProbe <> '' then
  begin
    WriteDiagLine('First designator in reference channel: "' + suffixProbe + '"');
    WriteDiagLine('Expected suffix: "_' + ChanNames[0] + '"');
    { Check whether it ends with the expected suffix }
    if AnsiUpperCase(StripChannelSuffix(suffixProbe, ChanNames[0])) <>
       AnsiUpperCase(suffixProbe) then
      WriteDiagLine('OBSERVED_SUFFIX_PATTERN: suffix "_' + ChanNames[0] +
                    '" IS present in reference designator (strip succeeded)')
    else
      WriteDiagLine('OBSERVED_SUFFIX_PATTERN: suffix "_' + ChanNames[0] +
                    '" NOT found in reference designator "' + suffixProbe +
                    '" -- designator-format mismatch LIKELY ROOT CAUSE');
  end
  else
    WriteDiagLine('OBSERVED_SUFFIX_PATTERN: no reference-channel designator was sampled' +
                  ' (class had 0 members in sample loop -- check CountClassMembers above)');

  { ---- Probe B: Iterator total vs class-member sum ---- }
  WriteDiagLine('');
  WriteDiagLine('=== PROBE B: Iterator vs class-member-sum ===');
  iterTotal := CountBoardComponents(Board);
  classMemberSum := 0;
  for i := 0 to N - 1 do
  begin
    Cls := FindClassByName(Board, ChanNames[i]);
    if Cls <> Nil then
      classMemberSum := classMemberSum + CountClassMembers(Board, Cls);
  end;
  WriteDiagLine('Full-board eComponentObject iterator total: ' + IntToStr(iterTotal));
  WriteDiagLine('Sum of CountClassMembers across all ' + IntToStr(N) +
                ' channel classes: ' + IntToStr(classMemberSum));
  if classMemberSum = 0 then
    WriteDiagLine('PROBE B RESULT: classMemberSum=0 -- IsMember never returns true.' +
                  ' Likely class mismatch, union shadowing, or wrong MemberKind.')
  else if Abs(iterTotal - classMemberSum) > N then
    WriteDiagLine('PROBE B RESULT: large discrepancy (' +
                  IntToStr(iterTotal - classMemberSum) +
                  '). Components visible to iterator but not to IsMember.' +
                  ' Union or class-membership registration may be stale.' +
                  ' Try Project > Compile PCB Project and rerun.')
  else
    WriteDiagLine('PROBE B RESULT: counts within expected tolerance (N=' +
                  IntToStr(N) + ' channels, some components may be in no channel class).');

  // ---- Probe C: Union probe ----
  // DISABLED: no verified union-membership accessor exists on IPCB_Component
  // for AD25/AD26 in the prior-art corpus. Comp.GroupId was the agent's
  // [deduced] guess and DelphiScript rejects it at compile time
  // ("Undeclared identifier: GroupId"). UnionId / UnionIndex / Union are
  // also unverified.
  //
  // To test the union hypothesis manually: in Altium, right-click the
  // unionised component > Component Actions > Break Union, then rerun
  // this diagnostic. If resetMatched goes from 0 to non-zero, the union
  // mattered. If it stays 0, the union is not the cause.
  WriteDiagLine('');
  WriteDiagLine('=== PROBE C: Union membership ===');
  WriteDiagLine('PROBE C RESULT: SKIPPED -- no verified union accessor API.');
  WriteDiagLine('See ProbeUnionMembership comment for manual test procedure.');

  { ---- Final summary ---- }
  WriteDiagLine('');
  WriteDiagLine('=== Summary ===');
  WriteDiagLine('resetMatched (should be > 0 if working): ' + IntToStr(resetMatched));
  WriteDiagLine('Log written to: ' + logPath);
  WriteDiagLine('');
  CloseDiagLog;

  ShowMessage('Diagnostic run complete.' + #13#10 +
              IntToStr(N) + ' channels examined. ' + #13#10 +
              'Reset snapped ' + IntToStr(resetMatched) + ' components (0 = root cause found in log).' + #13#10 +
              'Polar transform was NOT run.' + #13#10 + #13#10 +
              'Log written to:' + #13#10 + logPath);

  ChanNames.Free;
end;
