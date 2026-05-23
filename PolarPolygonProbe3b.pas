{ ===========================================================================
  PolarPolygonProbe3b.pas

  Probe-3 (PointX[i]) failed at compile time: "Undeclared identifier:
  PointX". So the array-indexer-property shape isn't right on AD26.

  Probe-3b tries the SEGMENT-LIST shape -- Poly.Segments[i] returning a
  TPolySegment record with .Kind, .vx, .vy, .cx, .cy, .angle fields.
  This is the canonical Altium polygon-outline API per published SDK
  docs (status [deduced] -- no corpus prior art).

  If THIS probe compiles + runs, we have READ access to outline
  vertices. If it fails too, probe-3c will try Poly.GetState_Segments(i)
  or Poly.OutlineSegment(i).

  Strategy reminder: ONE new property per probe. Try/except cannot
  catch a compile-time-undeclared identifier on AD26.

  Output: C:\Users\Public\PolarPolygonProbe3b.txt
=========================================================================== }

function P3b_Fmt(c : TCoord) : String;
begin
  Result := FloatToStrF(CoordToMMs(c), ffFixed, 12, 4);
end;

function P3b_LayerName(Board : IPCB_Board; layer : Integer) : String;
begin
  Result := IntToStr(layer);
  try
    Result := IntToStr(layer) + ':' + Board.LayerName(layer);
  except
  end;
end;

procedure RunPolygonProbe3b;
var
  Board : IPCB_Board;
  Iter  : IPCB_BoardIterator;
  Prim  : IPCB_Primitive;
  Poly  : IPCB_Polygon;
  seg   : TPolySegment;
  Lines : TStringList;
  outFile : String;
  totalPoly, emitted, i : Integer;
  pointCount : Integer;
  readOK : Boolean;
begin
  Board := PCBServer.GetCurrentPCBBoard;
  if Board = Nil then
  begin
    ShowMessage('ERROR: No PCB document is currently active.');
    Exit;
  end;

  Lines := TStringList.Create;
  Lines.Add('=== Polar Polygon Probe 3b ===');
  Lines.Add('Generated : ' + DateTimeToStr(Now));
  Lines.Add('Board     : ' + Board.FileName);
  Lines.Add('');
  Lines.Add('After probe-3 failed (PointX undeclared), this probe tests');
  Lines.Add('Poly.Segments[i] returning TPolySegment. Reads .Kind, .vx,');
  Lines.Add('.vy, .cx, .cy, .angle fields per segment.');
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

      if emitted < 8 then
      begin
        pointCount := 0;
        try
          pointCount := Poly.PointCount;
        except
          pointCount := 0;
        end;

        Lines.Add('POLY[' + IntToStr(totalPoly) + ']' +
                  '  layer=' + P3b_LayerName(Board, Prim.Layer) +
                  '  PointCount=' + IntToStr(pointCount));

        for i := 0 to pointCount - 1 do
        begin
          readOK := False;
          try
            seg := Poly.Segments[i];
            readOK := True;
          except
            readOK := False;
          end;
          if readOK then
            Lines.Add('  S[' + IntToStr(i) + ']' +
                      '  Kind=' + IntToStr(seg.Kind) +
                      '  vx=' + P3b_Fmt(seg.vx) + 'mm' +
                      '  vy=' + P3b_Fmt(seg.vy) + 'mm' +
                      '  cx=' + P3b_Fmt(seg.cx) + 'mm' +
                      '  cy=' + P3b_Fmt(seg.cy) + 'mm' +
                      '  angle=' + FloatToStrF(seg.angle, ffFixed, 10, 4))
          else
            Lines.Add('  S[' + IntToStr(i) + '] = (read failed)');
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
  Lines.Add('  Kind=0 typically = line segment, Kind=1 = arc segment.');
  Lines.Add('  For line segments, only vx/vy matter (cx/cy/angle are 0).');
  Lines.Add('  For arc segments, all six fields are meaningful.');
  Lines.Add('');
  Lines.Add('  If S[0]..S[N-1] vx/vy values land inside the polygon bbox,');
  Lines.Add('  READ via Segments[i] is verified.');

  outFile := 'C:\Users\Public\PolarPolygonProbe3b.txt';
  Lines.SaveToFile(outFile);
  Lines.Free;

  ShowMessage('Probe 3b complete. Output: ' + outFile);
end;

begin
  RunPolygonProbe3b;
end.
