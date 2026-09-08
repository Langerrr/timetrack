import unittest
from ttreport.intervals import union, total, clip, split_days


class TestUnion(unittest.TestCase):
    def test_disjoint_spans_are_kept_apart(self):
        self.assertEqual(union([(0, 10), (20, 30)]), [(0, 10), (20, 30)])

    def test_overlapping_spans_merge(self):
        self.assertEqual(union([(0, 10), (5, 20)]), [(0, 20)])

    def test_touching_spans_merge(self):
        self.assertEqual(union([(0, 10), (10, 20)]), [(0, 20)])

    def test_contained_span_disappears(self):
        self.assertEqual(union([(0, 100), (10, 20)]), [(0, 100)])

    def test_unsorted_input_is_handled(self):
        self.assertEqual(union([(20, 30), (0, 10), (5, 25)]), [(0, 30)])

    def test_empty_and_inverted_spans_are_dropped(self):
        self.assertEqual(union([(5, 5), (10, 4), (0, 3)]), [(0, 3)])

    def test_parallel_sessions_collapse_to_one_hour(self):
        # Two sessions attended for the same hour are one hour of effort.
        self.assertEqual(total(union([(0, 3600), (0, 3600)])), 3600)


class TestTotal(unittest.TestCase):
    def test_total_sums_without_merging(self):
        # Machine time sums; five parallel workers are five workers.
        self.assertEqual(total([(0, 600)] * 5), 3000)

    def test_total_of_empty_is_zero(self):
        self.assertEqual(total([]), 0)


class TestClip(unittest.TestCase):
    def test_span_is_trimmed_to_the_window(self):
        self.assertEqual(clip([(0, 100)], 10, 50), [(10, 50)])

    def test_span_outside_the_window_is_dropped(self):
        self.assertEqual(clip([(0, 5)], 10, 50), [])

    def test_span_inside_the_window_is_untouched(self):
        self.assertEqual(clip([(20, 30)], 10, 50), [(20, 30)])


class TestSplitDays(unittest.TestCase):
    def test_span_within_one_day_is_not_split(self):
        self.assertEqual(split_days([(10, 20)], [0, 100]), [(0, (10, 20))])

    def test_span_crossing_a_boundary_is_cut(self):
        self.assertEqual(
            split_days([(50, 150)], [0, 100, 200]),
            [(0, (50, 100)), (100, (100, 150))],
        )

    def test_span_before_the_first_boundary_is_dropped(self):
        self.assertEqual(split_days([(0, 50)], [100, 200]), [])

    def test_span_straddling_the_first_boundary_keeps_its_tail(self):
        self.assertEqual(split_days([(50, 150)], [100, 200]),
                         [(100, (100, 150))])

    def test_span_crossing_several_boundaries_is_cut_at_each(self):
        self.assertEqual(
            split_days([(50, 250)], [0, 100, 200]),
            [(0, (50, 100)), (100, (100, 200)), (200, (200, 250))],
        )


if __name__ == "__main__":
    unittest.main()
