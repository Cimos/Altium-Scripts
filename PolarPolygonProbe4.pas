{ ===========================================================================
  PolarPolygonProbe4.pas

  Probe-4 in the polygon API discovery sequence.

  Verified so far (probes 1-3b):
    - ePolyObject = 10, eRegionObject = 11
    - Poly.PointCount  (probe-2)
    - Poly.Segments[i] returns TPolySegment  (probe-3b)
    - seg.Kind, seg.vx, seg.vy, seg.cx, seg.cy  (probe-3b)
    - seg.angle is undeclared on AD26  (probe-3b)

  This probe tests the WRITE shape: Poly.Segments[i] := seg.

  SAFE-BY-DESIGN: round-trip with no actual modification. Reads each
  segment, immediately writes it back unchanged. If the setter pattern
  works, this is a no-op on the board. If it fails to compile, we
  learn the right shape isn't `Segments[i] := value` and probe-4b will
  try SetState_Segments(i, value).

  Transaction wrap: PCBServer.PreProcess/PostProcess (verified pattern,
  used in PolarChannelArray.pas:1838 and :1880). NOT using BeginModify
  -- that's flagged UNVERIFIED in [[feedback-delphiscript-on-ad26]].

  Output: C:\Users\Public\PolarPolygonProbe4.txt
=========================================================================== }

function P4_Fmt(c : TCoord) : String;
begin
  Result := FloatToStrF(CoordToMMs(c), ffFixed, 12, 4);
end;

procedure RunPolygonProbe4;
var
  Board : IPCB_Board;
  Iter  : IPCB_BoardIterator;
  Prim  : IPCB_Primitive;
  Poly  : IPCB_Polygon;
  seg   : TPolySegment;
  Lines : TStringList;
  outFile : String;
  totalPoly, processed, writeOK, writeFail, i : Integer;
  pointCount : Integer;
  writeSucceeded : Boolean;
begin
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = Nil then
  begin
    ShowMessage('ERROR: No PCB document is currently active.');
    Exit;
  end;

  Lines := TStringList.Create;
  Lines.Add('=== Polar Polygon Probe 4 ===');
  Lines.Add('Generated : ' + DateTimeToStr(Now));
  Lines.Add('Board     : ' + Board.FileName);
  Lines.Add('');
  Lines.Add('Tests WRITE accessor: Poly.Segments[i] := seg.');
  Lines.Add('Safe-by-design: round-trips each segment (reads + writes');
  Lines.Add('unchanged) so the board is not modified even if write succeeds.');
  Lines.Add('');

  totalPoly := 0;
  processed := 0;
  writeOK := 0;
  writeFail := 0;

  PCBServer.PreProcess;

  Iter := Board.BoardIterator_Create;
  Iter.AddFilter_ObjectSet(MkSet(ePolyObject));
  Iter.AddFilter_LayerSet(AllLayers);
  Iter.AddFilter_Method(eProcessAll);

  Prim := Iter.FirstPCBObject;
  while Prim <> Nil do
  begin
    if Prim.ObjectId = ePolyObject then
    begin
      totalPoly := totalPoly + 1;
      Poly := Prim;

      pointCount := 0;
      try
        pointCount := Poly.PointCount;
      except
        pointCount := 0;
      end;

      writeSucceeded := True;
      for i := 0 to pointCount - 1 do
      begin
        try
          seg := Poly.Segments[i];
          { THE TEST: assignment back to Segments[i]. If this fails to
            compile, the probe never runs. If it raises at runtime
            (e.g. read-only indexer), the per-segment try/except catches. }
          Poly.Segments[i] := seg;
        except
          writeSucceeded := False;
        end;
      end;

      if writeSucceeded then writeOK := writeOK + 1
      else writeFail := writeFail + 1;

      processed := processed + 1;
      if processed <= 8 then
      begin
        if writeSucceeded then
          Lines.Add('POLY[' + IntToStr(totalPoly) + ']' +
                    '  PointCount=' + IntToStr(pointCount) +
                    '  roundtrip=OK')
        else
          Lines.Add('POLY[' + IntToStr(totalPoly) + ']' +
                    '  PointCount=' + IntToStr(pointCount) +
                    '  roundtrip=FAILED');
      end;
    end;
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  PCBServer.PostProcess;

  Lines.Add('');
  Lines.Add('-- Summary --');
  Lines.Add('  polygons enumerated  : ' + IntToStr(totalPoly));
  Lines.Add('  round-trip OK        : ' + IntToStr(writeOK));
  Lines.Add('  round-trip FAILED    : ' + IntToStr(writeFail));
  Lines.Add('');
  Lines.Add('-- Interpretation --');
  Lines.Add('  - All OK -> Segments[i] := seg is the right write API.');
  Lines.Add('    We can build the polygon-mover with this shape.');
  Lines.Add('  - Compile fail (this script never ran) -> indexer is');
  Lines.Add('    read-only. Probe-4b will try SetState_Segments(i, seg)');
  Lines.Add('    or AddPolySegment / RemovePolySegment patterns.');
  Lines.Add('  - All FAILED (compile passed but runtime raise) -> setter');
  Lines.Add('    exists but pattern is wrong. Likely needs BeginModify or');
  Lines.Add('    a different argument shape.');
  Lines.Add('');
  Lines.Add('  Verify after this probe: open the board. Nothing should');
  Lines.Add('  have changed visually. If anything moved, the round-trip');
  Lines.Add('  is not a true no-op (would indicate the read returns a');
  Lines.Add('  re-canonicalised value).');

  outFile := 'C:\Users\Public\PolarPolygonProbe4.txt';
  Lines.SaveToFile(outFile);
  Lines.Free;

  ShowMessage('Probe 4 complete. Output: ' + outFile +
              #13#10 + #13#10 +
              'Visually verify the board has not changed.');
end;

begin
  RunPolygonProbe4;
end.
