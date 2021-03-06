-- ==
-- input {
--   [[1,2,3],[4,5,6],[7,8,9]]
-- }
-- output {
--   [[3, 4, 5], [7, 9, 11], [14, 17, 20]]
-- }
-- structure { Map 2 Scan 1 }
fun [[int]] main([[int,3]] input) =
  let x = scan(fn [int,3] ([int] a, [int] b) =>
                 map(+, zip(a, b)),
               replicate(3, 0), input) in
  map(fn [int,3] ([int] r) =>
        map(+ (2), r),
      x)
