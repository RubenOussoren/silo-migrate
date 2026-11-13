"""Public dependency preparation only; Docker, downloads and installs are faked."""
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load():
    loader = importlib.machinery.SourceFileLoader('prepare_merge_dependencies', str(ROOT / 'script/prepare-discourse-mcp'))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class MergeDependencyPreparationTest(unittest.TestCase):
    def setUp(self):
        self.helper = load()
        self.connector = types.SimpleNamespace(
            runtime_pin=mock.Mock(return_value=({'package': '@discourse/mcp', 'package_version': '0.3.1'}, 'a' * 64)),
            connector_ready=mock.Mock(return_value=('verified', 'image')),
            prepare_connector=mock.Mock(return_value={'version': 1, 'status': 'ready'}))
        self.data = types.SimpleNamespace(dbhub_image=mock.Mock(return_value=True))
        self.output, self.error = io.StringIO(), io.StringIO()
        patcher = mock.patch.object(self.helper, 'load_peer', side_effect=lambda name: {'merge_mcp': self.connector, 'data_tools': self.data}[name])
        patcher.start()
        self.addCleanup(patcher.stop)

    def invoke(self, args):
        with mock.patch('sys.stdout', self.output), mock.patch('sys.stderr', self.error):
            return self.helper.main(args)

    def test_check_reports_both_dependencies_without_download(self):
        self.data.dbhub_image.return_value = False
        self.assertEqual(1, self.invoke(['--check']))
        receipt = json.loads(self.output.getvalue())
        self.assertEqual((False, True, False), (receipt['ready'], receipt['site_ready'], receipt['source_ready']))
        self.data.dbhub_image.assert_called_once_with(0)
        self.connector.prepare_connector.assert_not_called()

    def test_check_ready_requires_site_and_source(self):
        self.assertEqual(0, self.invoke(['--check']))
        self.assertTrue(json.loads(self.output.getvalue())['ready'])
        self.data.dbhub_image.assert_called_once_with(0)

    def test_normal_update_prepares_both_public_dependencies(self):
        self.assertEqual(0, self.invoke([]))
        self.assertTrue(self.connector.prepare_connector.call_args.kwargs['pull'])
        self.data.dbhub_image.assert_called_once_with(300)
        self.assertTrue(json.loads(self.output.getvalue())['source_ready'])

    def test_no_pull_never_downloads_either_dependency(self):
        self.assertEqual(0, self.invoke(['--no-pull']))
        self.assertFalse(self.connector.prepare_connector.call_args.kwargs['pull'])
        self.data.dbhub_image.assert_called_once_with(0)

    def test_missing_source_runtime_refuses_release_preparation(self):
        self.data.dbhub_image.return_value = False
        self.assertEqual(1, self.invoke([]))
        self.assertEqual('', self.output.getvalue())
        self.assertEqual('MERGE_MCP_PREPARE_FAILED: pinned source DBHub runtime unavailable\n', self.error.getvalue())


if __name__ == '__main__':
    unittest.main()
