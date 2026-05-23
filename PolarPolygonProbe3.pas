{ ===========================================================================
  PolarPolygonProbe3.pas

  Probe-3 in the polygon API discovery sequence.

  Verified so far (probes 1 + 2):
    - ePolyObject = 10
    - eRegionObject = 11
    - Prim.Layer / Prim.BoundingRectangle.* / Prim.Component
    - Poly.PointCount  (probe-2; all 23 polygons returned sane integers)

  This probe adds TWO new accessors (both required to navigate a
  polygon outline): Poly.PointX[i] and Poly.PointY[i] for i in
  0..PointCount-1.

  These are the standard Altium-array-indexer pattern. If either fails
  to compile, probe-3b will try alternative shapes:
    - Poly.GetState_PointX(i) / Poly.GetState_PointY(i)
    - Poly.Segments[i].X / Poly.Segments[i].Y
    - Poly.Vertices[i].X / Poly.Vertices[i].Y

  We need WORKING vertex read AND write for the polygon-mover. This
  probe tests READ only. Write is the next probe (probe-4).

  Output: C:\Users\Public\PolarPolygonProbe3.txt
=========================================================================== }

function P3_Fmt(c : TCoord) : String;
begin
  Result := FloatToStrF(CoordToMMs(c), ffFixed, 12, 4);
end;

function P3_LayerName(Board : IPCB_Board; layer : Integer) : String;
begin
  Result := IntToStr(layer);
  try
    Result := IntToStr(layer) + ':' + Board.LayerName(layer);
  except
  end;
end;

procedure RunPolygonProbe3;
var
  Board : IPCB_Board;
  Iter  : IPCB_BoardIterator;
  Prim  : IPCB_Primitive;
  Poly  : IPCB_Polygon;
  Lines : TStringList;
  outFile : String;
  totalPoly, emitted, i : Integer;
  pointCount : Integer;
  px, py : TCoord;
  readOK : Boolean;
begin
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = Nil then
  begin
    ShowMessage('ERROR: No PCB document is currently active.');
    Exit;
  end;

  Lines := TStringList.Create;
  Lines.Add('=== Polar Polygon Probe 3 ===');
  Lines.Add('Generated : ' + DateTimeToStr(Now));
  Lines.Add('Board     : ' + Board.FileName);
  Lines.Add('');
  Lines.Add('Tests TWO new accessors: Poly.PointX[i], Poly.PointY[i].');
  Lines.Add('Reads first 8 polygons'' vertices and emits them. If the');
  Lines.Add('coordinates match the bbox corners (approximately), READ');
  Lines.Add('via array indexer is verified.');
  Lines.Add('');

  totalPoly := 0;
  emitted := 0;

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

      { Cap detailed emit at 8 polygons to keep output focused. The
        critical samples are POLY[7-18] (channel-specific quads on
        Layer 2); emitting 8 is plenty to confirm the API. }
      if emitted < 8 then
      begin
        pointCount := 0;
        try
          pointCount := Poly.PointCount;
        except
          pointCount := 0;
        end;

        Lines.Add('POLY[' + IntToStr(totalPoly) + ']' +
                  '  layer=' + P3_LayerName(Board, Prim.Layer) +
                  '  PointCount=' + IntToStr(pointCount) +
                  '  bbox=(' +
                  P3_Fmt(Prim.BoundingRectangle.Left) + ',' +
                  P3_Fmt(Prim.BoundingRectangle.Bottom) + ')-(' +
                  P3_Fmt(Prim.BoundingRectangle.Right) + ',' +
                  P3_Fmt(Prim.BoundingRectangle.Top) + ')');

        { THE TEST: indexed vertex read. If PointX[i] / PointY[i] are
          not valid array-indexer accessors on AD26, compile fails at
          one of the lines below. Runtime failures (Nil deref, bad
          index) caught by try/except per vertex. }
        for i := 0 to pointCount - 1 do
        begin
          readOK := False;
          px := 0;
          py := 0;
          try
            px := Poly.PointX[i];
            py := Poly.PointY[i];
            readOK := True;
          except
            readOK := False;
          end;
          if readOK then
            Lines.Add('  V[' + IntToStr(i) + '] = (' +
                      P3_Fmt(px) + ', ' + P3_Fmt(py) + ') mm')
          else
            Lines.Add('  V[' + IntToStr(i) + '] = (read failed)');
        end;

        emitted := emitted + 1;
        Lines.Add('');
      end;
    end;
    Prim := Iter.NextPCBObject;
  end;
  Board.BoardIterator_Destroy(Iter);

  Lines.Add('-- Summary --');
  Lines.Add('  polygons enumerated  : ' + IntToStr(totalPoly));
  Lines.Add('  emitted detail       : ' + IntToStr(emitted));
  Lines.Add('');
  Lines.Add('-- Interpretation --');
  Lines.Add('  - If each polygon shows V[0]..V[N-1] with sensible mm');
  Lines.Add('    coords inside the reported bbox, READ via PointX/PointY');
  Lines.Add('    is verified.');
  Lines.Add('  - "(read failed)" rows = property exists but raised at');
  Lines.Add('    runtime; likely indexed access is not the right shape.');
  Lines.Add('  - Compile fail = property names wrong on AD26; probe-3b');
  Lines.Add('    will try GetState_PointX/Y or Segments[i].X/Y.');
  Lines.Add('');
  Lines.Add('  Next probe (probe-4): test WRITE — Poly.PointX[i] := newX');
  Lines.Add('  on ONE polygon, with BeginModify/EndModify. Risky enough');
  Lines.Add('  to deserve its own probe + a test board, not the live one.');

  outFile := 'C:\Users\Public\PolarPolygonProbe3.txt';
  Lines.SaveToFile(outFile);
  Lines.Free;

  ShowMessage('Probe 3 complete. Output: ' + outFile);
end;

begin
  RunPolygonProbe3;
end.
